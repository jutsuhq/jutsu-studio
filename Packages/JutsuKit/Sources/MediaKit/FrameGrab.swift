import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Still frames of a video or an image as PNG files, and a contact sheet of several clips at the same times: what an
/// agent checks a result with instead of a video player. Local and free.
public enum FrameGrab {
    /// Whether `url` names an image rather than a video, by its extension.
    public static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// Seconds the video runs.
    public static func duration(of url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaError.unsupportedFormat }
        return duration
    }

    /// The frames of the video at `times`, in seconds from its start, oriented for display; the exact frame, not the
    /// nearest keyframe. `sending`: `CGImage` isn't `Sendable`.
    public static func frames(of url: URL, at times: [Double]) async throws -> sending [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [CGImage] = []
        for time in times {
            try Task.checkCancellation()
            let (image, _) = try await generator.image(
                at: CMTime(seconds: time, preferredTimescale: ThumbnailStrip.preferredTimescale))
            images.append(image)
        }
        return images
    }

    /// The image at `url`, upright.
    public static func still(at url: URL) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8192,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw MediaError.unreadableImage }
        return image
    }

    /// One image of `rows`, each frame scaled to `cellHeight` keeping its shape, `gap` pixels apart on black: a row
    /// per clip, a column per time. `nil` when there is nothing to draw.
    public static func sheet(_ rows: [[CGImage]], cellHeight: Int = 360, gap: Int = 8) -> CGImage? {
        let scaled = rows.map { row in
            row.map { image in
                let width = Double(image.width) * Double(cellHeight) / Double(max(1, image.height))
                return (image, max(1, Int(width.rounded())))
            }
        }
        let columns = scaled.map(\.count).max() ?? 0
        guard columns > 0 else { return nil }
        // Each column as wide as its widest frame, so the same time lines up down the sheet.
        let widths = (0..<columns).map { column in
            scaled.compactMap { column < $0.count ? $0[column].1 : nil }.max() ?? 0
        }
        let width = widths.reduce(gap) { $0 + $1 + gap }
        let height = gap + rows.count * (cellHeight + gap)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (rowIndex, row) in scaled.enumerated() {
            // Core Graphics counts from the bottom: the first row goes on top.
            let y = height - (rowIndex + 1) * (cellHeight + gap)
            var x = gap
            for (column, (image, cellWidth)) in row.enumerated() {
                let offset = (widths[column] - cellWidth) / 2
                context.draw(image, in: CGRect(x: x + offset, y: y, width: cellWidth, height: cellHeight))
                x += widths[column] + gap
            }
        }
        return context.makeImage()
    }

    /// Writes `image` as a PNG at `url`, which must not exist yet: nothing is written over.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MediaError.exportFailed("PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.exportFailed("PNG") }
    }
}
