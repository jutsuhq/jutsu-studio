import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import JutsuCore

public struct MediaInfo: Sendable, Hashable {
    public var duration: TimeInterval
    /// Display size: the natural size with the track's preferred transform (rotation) applied.
    public var pixelSize: PixelSize
    /// FourCC of the video codec, e.g. `avc1` or `hvc1`.
    public var codec: String
    /// Nominal frames per second.
    public var frameRate: Double
    public var fileSize: Int64
    public var hasAudio: Bool
}

public enum MediaProbe {
    /// Reads what the import screen shows. Throws `MediaError.unsupportedFormat` when there is no
    /// video track AVFoundation can play, so WebM and friends fail here instead of mid-export.
    /// A remote `url` is read through range requests for its header only; its file size is reported as 0.
    public static func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let (duration, playable) = try await unsupportedOnFailure { try await asset.load(.duration, .isPlayable) }
        let videoTracks = try await unsupportedOnFailure { try await asset.loadTracks(withMediaType: .video) }
        let audioTracks = try await unsupportedOnFailure { try await asset.loadTracks(withMediaType: .audio) }
        guard playable, let track = videoTracks.first else { throw MediaError.unsupportedFormat }

        let (naturalSize, transform, formats, frameRate) = try await track.load(
            .naturalSize, .preferredTransform, .formatDescriptions, .nominalFrameRate)
        guard let format = formats.first else { throw MediaError.unsupportedFormat }
        let fileSize = try url.isFileURL ? (url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) : 0

        return MediaInfo(
            duration: duration.seconds,
            pixelSize: displaySize(naturalSize: naturalSize, transform: transform),
            codec: fourCC(CMFormatDescriptionGetMediaSubType(format)),
            frameRate: Double(frameRate),
            fileSize: Int64(fileSize),
            hasAudio: !audioTracks.isEmpty
        )
    }

    /// AVFoundation reports unreadable containers with assorted `NSError`s; callers only need to know
    /// the file can't be used. Cancellation is passed through so a canceled job isn't marked failed.
    static func unsupportedOnFailure<T>(_ load: () async throws -> T) async throws -> T {
        do {
            return try await load()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw MediaError.unsupportedFormat
        }
    }

    static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> PixelSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return PixelSize(width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()))
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
