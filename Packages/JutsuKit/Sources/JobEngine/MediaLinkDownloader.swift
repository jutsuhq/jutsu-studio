import Foundation
import HiggsfieldCore
import JutsuCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A video or image downloaded from a link for Create.
public struct DownloadedMedia: Sendable, Hashable {
    public var fileURL: URL
    public var kind: MediaLink.Kind
    /// The link it came from: `SourceClip.remoteOrigin` / `LocalImage.remoteOrigin`.
    public var origin: URL
}

/// Downloads a pasted link with `URLSessionDownloader` (resume, size limit, free-space check) into a folder of its
/// own, and keeps it only when the server says it is a video or an image (`MediaLink.classify`), so a web page is
/// refused before its body is written. Failures throw `MediaLinkError`; cancelling throws `CancellationError`.
/// Either way nothing is left behind.
public struct MediaLinkDownloader: Sendable {
    /// Larger files are almost always the wrong link: a job takes at most 30 s of a source.
    public static let maxBytes: Int64 = 2 << 30

    private let session: URLSession
    private let maxBytes: Int64
    private let freeSpace: @Sendable (URL) -> Int64?

    public init(
        session: URLSession = .shared, maxBytes: Int64 = Self.maxBytes,
        freeSpace: @escaping @Sendable (URL) -> Int64? = URLSessionDownloader.freeSpace(for:)
    ) {
        self.session = session
        self.maxBytes = maxBytes
        self.freeSpace = freeSpace
    }

    /// Downloads `link` to `folder/<new id>/<name>.<ext>`.
    /// - Parameters:
    ///   - expected: the kind the caller can use; another kind throws `MediaLinkError.wrongKind` before the body is
    ///     downloaded. `nil` takes either.
    ///   - progress: the fraction done, `nil` while the size is unknown.
    public func download(
        _ link: URL, into folder: URL, expected: MediaLink.Kind? = nil,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> DownloadedMedia {
        guard link.isHTTPS else { throw MediaLinkError.notHTTPS }
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let partial = directory.appendingPathComponent(".download", isDirectory: false)
        let found = FoundType()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let downloader = URLSessionDownloader(session: session, maxBytes: maxBytes, freeSpace: freeSpace)
            try await downloader.download(
                link, to: partial,
                accept: { response in
                    let type = try MediaLink.classify(
                        contentType: response.value(forHTTPHeaderField: "Content-Type"), url: response.url ?? link)
                    if let expected, type.kind != expected { throw MediaLinkError.wrongKind(expected: expected) }
                    found.set(type)
                },
                progress: { written, total in
                    progress(total.map { $0 > 0 ? min(Double(written) / Double($0), 1) : 1 })
                })
            guard let type = found.value, Self.size(of: partial) > 0 else {
                throw MediaLinkError.notMedia(contentType: nil)
            }
            let named = ServerFileName.file(
                in: directory, named: [MediaLink.baseName(of: link)],
                extensionOf: URL(fileURLWithPath: "file.\(type.fileExtension)"), allowed: [type.fileExtension])
            guard let file = named else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.moveItem(at: partial, to: file)
            return DownloadedMedia(fileURL: file, kind: type.kind, origin: link)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw Self.linkError(error)
        }
    }

    /// Downloads `link` to `file`, unless a file is already there: for media a server keeps, saved once under a name
    /// the caller chose. The download goes into a folder of its own beside `file` and is renamed into place, so
    /// another download of the same file finishing first is replaced whole instead of failing this one.
    public func download(_ link: URL, to file: URL, expected: MediaLink.Kind) async throws {
        if FileManager.default.fileExists(atPath: file.path) { return }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let media = try await download(link, into: folder, expected: expected)
        defer { try? FileManager.default.removeItem(at: media.fileURL.deletingLastPathComponent()) }
        try FileReplacement.move(media.fileURL, to: file)
    }

    /// The downloader's errors as `MediaLinkError`; cancellation and anything unexpected pass through.
    static func linkError(_ error: any Error) -> any Error {
        switch error {
        case let error as MediaLinkError: error
        case JobEngineError.downloadRefused(.tooLarge(let maxBytes)): MediaLinkError.tooLarge(maxBytes: maxBytes)
        case JobEngineError.downloadRefused(.notHTTPS): MediaLinkError.notHTTPS
        case JobEngineError.downloadRefused(.stalled): MediaLinkError.network
        case JobEngineError.downloadFailed(let status): MediaLinkError.unavailable(status: status)
        case ProviderError.server(let status): MediaLinkError.unavailable(status: status)
        case ProviderError.network: MediaLinkError.network
        case let error as CocoaError where error.code == .fileWriteOutOfSpace: MediaLinkError.notEnoughSpace
        default: error
        }
    }

    private static func size(of file: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        return size?.int64Value ?? 0
    }
}

/// The type the first accepted response had, set from the session's delegate queue.
private final class FoundType: @unchecked Sendable {
    // Safe: `type` is only touched under `lock`.
    private let lock = NSLock()
    private var type: (kind: MediaLink.Kind, fileExtension: String)?

    func set(_ type: (kind: MediaLink.Kind, fileExtension: String)) {
        lock.lock()
        defer { lock.unlock() }
        self.type = type
    }

    var value: (kind: MediaLink.Kind, fileExtension: String)? {
        lock.lock()
        defer { lock.unlock() }
        return type
    }
}
