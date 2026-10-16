import Foundation
import HiggsfieldCore
import JutsuCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Fetches a finished video.
public protocol Downloader: Sendable {
    /// Downloads `url` into `file`. Bytes already in `file` from an interrupted call are kept and only
    /// the rest is fetched, so calling again resumes.
    /// Throws `ProviderError.network` or `.server` for failures worth retrying.
    func download(_ url: URL, to file: URL) async throws
}

/// Fetches the video in `Range` requests of `chunkSize` bytes and streams each one to the end of the file,
/// so a failure loses at most one chunk and no body is held in memory. A server that ignores `Range` sends
/// the whole video at once. Only https URLs are fetched, and never more than `maxBytes` in all. A response whose
/// remaining size won't fit on the disk throws `CocoaError.fileWriteOutOfSpace` before anything is written.
public struct URLSessionDownloader: Downloader {
    private let session: URLSession
    private let chunkSize: UInt64
    private let maxAttempts: Int
    private let maxBytes: UInt64
    private let freeSpace: @Sendable (URL) -> Int64?

    /// - Parameters:
    ///   - session: its configuration is used; the requests run in a session of their own.
    ///   - maxAttempts: failures in a row before the error goes to the caller; a chunk that
    ///     arrives starts the count again.
    ///   - freeSpace: the bytes free for the given file, `nil` when unknown.
    public init(
        session: URLSession = .shared, chunkSize: Int = 8 << 20, maxAttempts: Int = 3, maxBytes: Int64 = 4 << 30,
        freeSpace: @escaping @Sendable (URL) -> Int64? = Self.freeSpace(for:)
    ) {
        self.session = session
        self.chunkSize = UInt64(max(chunkSize, 1))
        self.maxAttempts = max(maxAttempts, 1)
        self.maxBytes = UInt64(max(maxBytes, 0))
        self.freeSpace = freeSpace
    }

    /// The space free on the volume of `file`. On macOS the larger of the two counts: the one for important use
    /// includes purgeable space macOS frees on demand, but some volumes report it as zero.
    public static func freeSpace(for file: URL) -> Int64? {
        let folder = file.deletingLastPathComponent()
        #if os(macOS)
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            guard let values = try? folder.resourceValues(forKeys: keys) else { return nil }
            let counts = [
                values.volumeAvailableCapacity.map(Int64.init), values.volumeAvailableCapacityForImportantUsage,
            ]
            return counts.compactMap(\.self).max()
        #else
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: folder.path)
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        #endif
    }

    public func download(_ url: URL, to file: URL) async throws {
        try await download(url, to: file, accept: { _ in }, progress: { _, _ in })
    }

    /// `download(_:to:)`, plus:
    /// - Parameters:
    ///   - accept: sees every successful response before its body is written, and throws to refuse it.
    ///   - progress: the bytes in the file so far and the whole file's size when the server says it, after each
    ///     write.
    public func download(
        _ url: URL, to file: URL, accept: @escaping @Sendable (HTTPURLResponse) throws -> Void,
        progress: @escaping @Sendable (_ written: Int64, _ total: Int64?) -> Void
    ) async throws {
        guard url.isHTTPS else { throw JobEngineError.downloadRefused(.notHTTPS) }
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        let writer = ChunkWriter(
            handle: handle, maxBytes: maxBytes, freeSpace: { [freeSpace] in freeSpace(file) }, accept: accept,
            progress: progress)
        let streaming = URLSession(configuration: session.configuration, delegate: writer, delegateQueue: nil)
        defer { streaming.finishTasksAndInvalidate() }
        var failures = 0
        while true {
            do {
                if try await fetchNext(url, with: writer, in: streaming) { return }
                failures = 0
            } catch is ProviderError where failures + 1 < maxAttempts {
                failures += 1
            }
        }
    }

    /// Appends the next chunk at the end of the file. Returns `true` once the file is complete.
    private func fetchNext(_ url: URL, with writer: ChunkWriter, in streaming: URLSession) async throws -> Bool {
        let offset = try writer.offset()
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + chunkSize - 1)", forHTTPHeaderField: "Range")
        let (response, written) = try await writer.load(request, at: offset, in: streaming)
        let range = ContentRange(response)
        switch response.statusCode {
        case 206:
            guard range?.start == offset else { try writer.restart() }
            guard written > 0, let total = range?.total else { throw JobEngineError.downloadRefused(.stalled) }
            return offset + written >= total
        case 416:
            if offset > 0, range?.total == offset { return true }
            try writer.restart()
        case 200..<300:
            return true
        case 500...:
            throw ProviderError.server(status: response.statusCode)
        default:
            throw JobEngineError.downloadFailed(status: response.statusCode)
        }
    }
}

/// Writes the body of one request at a time into the file as it arrives. A 206 is written at the requested
/// offset only when its `Content-Range` starts there; another success replaces the file; anything else
/// is dropped.
private final class ChunkWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Safe: `handle` and `current` are only touched under `lock`.
    private let lock = NSLock()
    private let handle: FileHandle
    private let maxBytes: UInt64
    private let freeSpace: @Sendable () -> Int64?
    private let accept: @Sendable (HTTPURLResponse) throws -> Void
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var current: Transfer?

    private struct Transfer {
        let offset: UInt64
        let continuation: CheckedContinuation<(HTTPURLResponse, UInt64), any Error>
        /// Where the body goes in the file; `nil` drops it.
        var base: UInt64?
        /// The whole file's size, when the response says it.
        var total: UInt64?
        var written: UInt64 = 0
        var failure: (any Error)?
    }

    init(
        handle: FileHandle, maxBytes: UInt64, freeSpace: @escaping @Sendable () -> Int64?,
        accept: @escaping @Sendable (HTTPURLResponse) throws -> Void,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) {
        self.handle = handle
        self.maxBytes = maxBytes
        self.freeSpace = freeSpace
        self.accept = accept
        self.progress = progress
    }

    func offset() throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return try handle.offset()
    }

    /// The kept bytes don't match what the server has: start over, counted as a failed attempt.
    func restart() throws -> Never {
        lock.lock()
        defer { lock.unlock() }
        try handle.truncate(atOffset: 0)
        throw ProviderError.network
    }

    /// The response, and how many body bytes went into the file.
    func load(
        _ request: URLRequest, at offset: UInt64, in session: URLSession
    ) async throws -> (HTTPURLResponse, UInt64) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                current = Transfer(offset: offset, continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard var transfer = current else { return completionHandler(.cancel) }
        do {
            transfer.base = try base(for: response, offset: transfer.offset)
            transfer.total = Self.total(of: response)
            current = transfer
            completionHandler(.allow)
        } catch {
            transfer.failure = error
            current = transfer
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard var transfer = current, transfer.failure == nil else { return }
        do {
            if let base = transfer.base {
                let count = UInt64(data.count)
                guard base + transfer.written + count <= maxBytes else { throw tooLarge }
                try handle.write(contentsOf: data)
                transfer.written += count
                progress(Int64(base + transfer.written), transfer.total.map(Int64.init))
            }
        } catch {
            transfer.failure = error
            dataTask.cancel()
        }
        current = transfer
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let transfer = current
        current = nil
        lock.unlock()
        guard let transfer else { return }
        transfer.continuation.resume(
            with: Result {
                if let failure = transfer.failure { throw failure }
                if let error = error as? URLError {
                    throw error.code == .cancelled ? CancellationError() : ProviderError.network
                }
                if let error { throw error }
                return (
                    try HTTPURLResponse.required(task.response, networkError: ProviderError.network), transfer.written
                )
            })
    }

    private var tooLarge: JobEngineError { .downloadRefused(.tooLarge(maxBytes: Int64(maxBytes))) }

    /// Fails before writing what can't fit, rather than filling the disk up to the last byte.
    private func checkSpace(for bytes: UInt64) throws {
        guard let free = freeSpace(), free >= 0, UInt64(free) < bytes else { return }
        throw CocoaError(.fileWriteOutOfSpace)
    }

    /// The whole file's size: the total of a partial answer, else the length of a full one.
    private static func total(of response: URLResponse?) -> UInt64? {
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 206 { return ContentRange(http)?.total }
        return http.expectedContentLength > 0 ? UInt64(http.expectedContentLength) : nil
    }

    /// Where the body of `response` goes in the file; `nil` when it isn't part of the file.
    private func base(for response: URLResponse?, offset: UInt64) throws -> UInt64? {
        guard let http = response as? HTTPURLResponse else { return nil }
        if (200..<300).contains(http.statusCode) { try accept(http) }
        switch http.statusCode {
        case 206:
            let range = ContentRange(http)
            guard range?.start == offset else { return nil }
            guard let total = range?.total else { throw JobEngineError.downloadRefused(.stalled) }
            guard total <= maxBytes else { throw tooLarge }
            try checkSpace(for: total - min(offset, total))
            return offset
        case 200..<300:
            if http.expectedContentLength > 0, UInt64(http.expectedContentLength) > maxBytes { throw tooLarge }
            try handle.truncate(atOffset: 0)
            if http.expectedContentLength > 0 { try checkSpace(for: UInt64(http.expectedContentLength)) }
            return 0
        default:
            return nil
        }
    }
}

/// `Content-Range: bytes <start>-<end>/<total>`, or `bytes */<total>` on 416. `total` is `nil` for `*`.
private struct ContentRange {
    var start: UInt64?
    var total: UInt64?

    init?(_ response: HTTPURLResponse) {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes ") else {
            return nil
        }
        let parts = value.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        start = parts[0].split(separator: "-").first.flatMap { UInt64($0) }
        total = UInt64(parts[1])
    }
}
