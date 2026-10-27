import CryptoKit
import Foundation
import JutsuCore

/// Downloads a model's pinned files (`ModelManifest`) into a folder of the app's own, a piece at a time, so a download
/// that stops resumes from its last piece; each file is checked against its hash before it takes its name.
public struct ModelDownloader: SpeechModelDownloading {
    /// Bytes asked for at once: what a stopped download loses at most.
    static let pieceSize: Int64 = 8 << 20

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func isComplete(_ manifest: ModelManifest, in folder: URL) -> Bool {
        manifest.files.allSatisfy { Self.size(at: folder.appending(path: $0.path)) == $0.size }
    }

    public func download(
        _ manifest: ModelManifest, into folder: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let total = Double(max(manifest.size, 1))
        var done: Int64 = 0
        for file in manifest.files {
            let destination = folder.appending(path: file.path)
            if Self.size(at: destination) == file.size {
                done += file.size
                continue
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("part")
            try await fetch(file, of: manifest, to: partial) { written in
                progress(Double(done + written) / total)
            }
            guard try Self.matches(partial, file) else {
                try? FileManager.default.removeItem(at: partial)
                throw ModelDownloadError.checksumMismatch(file.path)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            done += file.size
            progress(Double(done) / total)
        }
    }

    public func size(of folder: URL) -> Int64 {
        guard
            let files = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    public func remove(_ folder: URL) throws {
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Appends the rest of the file to `partial`, a piece at a time, from where it ends.
    private func fetch(
        _ file: ModelManifest.File, of manifest: ModelManifest, to partial: URL,
        progress: (Int64) -> Void
    ) async throws {
        guard let url = manifest.url(of: file) else { throw ModelDownloadError.badResponse(file.path) }
        if Self.size(at: partial).map({ $0 > file.size }) ?? false { try FileManager.default.removeItem(at: partial) }
        if !FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        progress(Int64(offset))
        while Int64(offset) < file.size {
            try Task.checkCancellation()
            let end = min(Int64(offset) + Self.pieceSize, file.size) - 1
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, offset == 0, Int64(data.count) == file.size {
                // A server that sends the whole small file at once.
            } else if status != 206 || Int64(data.count) != end - Int64(offset) + 1 {
                throw ModelDownloadError.badResponse(file.path)
            }
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
            progress(Int64(offset))
        }
    }

    static func size(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?
            .int64Value
    }

    /// Whether the file's content hashes to what the manifest says: SHA-256, or Git's blob hash.
    static func matches(_ url: URL, _ file: ModelManifest.File) throws -> Bool {
        guard size(at: url) == file.size else { return false }
        if let sha256 = file.sha256 { return try ContentHasher.sha256Hex(ofFileAt: url) == sha256 }
        if let gitBlob = file.gitBlob {
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(file.size)\u{0}".utf8))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined() == gitBlob
        }
        return false
    }
}

public enum ModelDownloadError: Error, Sendable, Equatable {
    /// The file came down with other content than the pinned revision has; it was deleted.
    case checksumMismatch(String)
    /// The server answered with something other than the piece asked for.
    case badResponse(String)
}

extension ModelDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .checksumMismatch(let path):
            String(localized: "\(path) didn't match the model's checksum and was deleted. Try again.", bundle: .module)
        case .badResponse(let path):
            String(localized: "The server didn't send \(path) as asked. Try again later.", bundle: .module)
        }
    }
}
