import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Evenly spaced frames for the trim timeline.
public enum ThumbnailStrip {
    /// Timescale for the frame timestamps: exact for millisecond math, cheap for the generator.
    static let preferredTimescale: Int32 = 600

    /// `count` frames, each taken from the middle of its slice of the video, oriented for display
    /// and no larger than `maximumSize`. `sending`: `CGImage` isn't `Sendable`, and callers keep
    /// the frames on the main actor.
    public static func images(
        for url: URL, count frames: Int, maximumSize: CGSize = CGSize(width: 320, height: 320)
    ) async throws -> sending [CGImage] {
        guard frames > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw MediaError.unsupportedFormat }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        let times = (0..<frames).map { index in
            CMTime(
                seconds: duration * (Double(index) + 0.5) / Double(frames),
                preferredTimescale: Self.preferredTimescale)
        }

        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: _):
                images.append(image)
            case .failure(requestedTime: _, error: let error):
                throw error
            }
        }
        return images
    }
}
