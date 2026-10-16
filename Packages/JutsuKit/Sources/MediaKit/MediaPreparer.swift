import CoreMedia
import Foundation
import JutsuCore

/// `MediaPreparing` on AVFoundation and ImageIO. Results land in `workingDirectory`, named after the
/// source content and the options, so preparing the same input again returns the existing file.
public struct MediaPreparer: MediaPreparing {
    /// Largest upload the API accepts.
    public static let fileLengthLimit: Int64 = 200 * 1024 * 1024
    /// Longest side of a prepared image, in pixels.
    public static let maximumImagePixelSize = 4096
    /// An export may end up to this much shorter than asked (last frame duration, rounding).
    static let durationTolerance: TimeInterval = 0.5

    public let workingDirectory: URL
    /// Source and output hashes, so a cache hit or a resumed job doesn't read the files again.
    let hashes: FileHashCache

    /// - Parameter hashes: defaults to a cache saved in `workingDirectory`.
    public init(workingDirectory: URL, hashes: FileHashCache? = nil) {
        self.workingDirectory = workingDirectory
        self.hashes = hashes ?? FileHashCache(storeURL: workingDirectory.appendingPathComponent("hashes.json"))
    }

    public func prepareVideo(
        _ source: SourceClip, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedFile {
        try await source.withAccess { url in
            try await prepareVideo(source, from: url, progress: progress)
        }
    }

    /// `url` is the source file with access already started; `source.fileURL` may be stale.
    private func prepareVideo(
        _ source: SourceClip, from url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedFile {
        let info = try await MediaProbe.probe(url)
        let start = max(0, source.range.lowerBound)
        let end = min(source.range.upperBound, info.duration)
        guard end > start else { throw MediaError.invalidRange }
        let renderSize =
            source.allowsUpscale
            ? Validation.upscaledSize(width: info.pixelSize.width, height: info.pixelSize.height) : info.pixelSize

        let sourceHash = try contentHash(ofFileAt: url)
        let key = ContentHasher.sha256Hex(
            of: "video|\(sourceHash)|\(start)|\(end)|\(renderSize.width)x\(renderSize.height)")
        let output = workingDirectory.appendingPathComponent(key).appendingPathExtension("mp4")
        if let cached = try cachedFile(at: output, contentType: "video/mp4") {
            progress(1)
            return cached
        }

        let request = VideoRequest(
            sourceURL: url,
            timeRange: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)),
            upscaledSize: renderSize == info.pixelSize ? nil : renderSize,
            byteLimit: Self.fileLengthLimit
        )
        let partial = try partialURL(for: output)
        defer { try? FileManager.default.removeItem(at: partial) }

        try await VideoExport.export(request, to: partial, progress: progress)
        // `fileLengthLimit` truncates instead of failing, so a short result means the preset didn't fit.
        let exported = try await MediaProbe.probe(partial)
        if exported.fileSize > request.byteLimit || exported.duration < end - start - Self.durationTolerance {
            try FileManager.default.removeItem(at: partial)
            try await VideoReencoder.reencode(request, to: partial, progress: progress)
            let size = try fileSize(at: partial)
            guard size <= request.byteLimit else { throw MediaError.tooLarge(byteCount: size) }
        }
        return try finish(partial, as: output, contentType: "video/mp4")
    }

    func cachedFile(at url: URL, contentType: String) throws -> PreparedFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try preparedFile(at: url, contentType: contentType)
    }

    /// A unique scratch path next to `output`; finished work is moved into place in one step, so a
    /// cancelled or failed run never leaves a half-written file under the cache name.
    func partialURL(for output: URL) throws -> URL {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let name = "\(output.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial"
        return workingDirectory.appendingPathComponent(name).appendingPathExtension(output.pathExtension)
    }

    func finish(_ partial: URL, as output: URL, contentType: String) throws -> PreparedFile {
        do {
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            // A concurrent call for the same input may have finished first; its file has the same content.
            guard FileManager.default.fileExists(atPath: output.path) else { throw error }
        }
        return try preparedFile(at: output, contentType: contentType)
    }

    private func preparedFile(at url: URL, contentType: String) throws -> PreparedFile {
        try PreparedFile(
            fileURL: url,
            contentType: contentType,
            byteCount: fileSize(at: url),
            contentHash: contentHash(ofFileAt: url)
        )
    }

    func contentHash(ofFileAt url: URL) throws -> String {
        try hashes.hash(ofFileAt: url, compute: ContentHasher.sha256Hex(ofFileAt:))
    }

    private func fileSize(at url: URL) throws -> Int64 {
        try Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    public func outputMedia(of file: URL) async -> OutputMedia? {
        guard let info = try? await MediaProbe.probe(file), info.duration.isFinite, info.duration > 0,
            info.pixelSize.isValid
        else { return nil }
        return OutputMedia(duration: info.duration, pixelSize: info.pixelSize)
    }
}

/// What to cut out of a source video and how big the result may be.
struct VideoRequest {
    var sourceURL: URL
    var timeRange: CMTimeRange
    /// Set only when the frame has to grow for object swap.
    var upscaledSize: PixelSize?
    var byteLimit: Int64
}
