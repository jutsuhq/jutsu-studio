import CoreGraphics
import Foundation
import ImageIO
import JutsuCore
import UniformTypeIdentifiers

extension MediaPreparer {
    /// JPEG and PNG within `maximumImagePixelSize` are passed through untouched. Everything else
    /// (HEIC, TIFF, oversized) is decoded with its orientation applied, downscaled and saved as JPEG.
    public func prepareImage(_ image: LocalImage) async throws -> PreparedFile {
        try Task.checkCancellation()
        return try await image.withAccess { url in
            try prepareImage(at: url)
        }
    }

    /// Read from the file's header; EXIF orientations 5–8 turn the image a quarter, so its sides swap.
    public func imageSize(of image: LocalImage) async -> PixelSize? {
        guard image.fileURL.isFileURL else { return nil }
        return try? await image.withAccess { ImageThumbnail.size(at: $0) }
    }

    /// `url` is the image file with access already started.
    private func prepareImage(at url: URL) throws -> PreparedFile {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let cfType = CGImageSourceGetType(source)
        else { throw MediaError.unreadableImage }

        let sourceType = cfType as String
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let fitsAsIs = width > 0 && height > 0 && max(width, height) <= Self.maximumImagePixelSize
        let passThroughType = [UTType.jpeg, UTType.png].first { $0.identifier == sourceType && fitsAsIs }
        let outputType = passThroughType ?? .jpeg
        let contentType = outputType.preferredMIMEType ?? "image/jpeg"

        let sourceHash = try contentHash(ofFileAt: url)
        let key = ContentHasher.sha256Hex(of: "image|\(sourceHash)|\(Self.maximumImagePixelSize)")
        let output = workingDirectory.appendingPathComponent(key)
            .appendingPathExtension(outputType.preferredFilenameExtension ?? "jpg")
        if let cached = try cachedFile(at: output, contentType: contentType) {
            return cached
        }

        let partial = try partialURL(for: output)
        defer { try? FileManager.default.removeItem(at: partial) }
        if passThroughType != nil {
            try FileManager.default.copyItem(at: url, to: partial)
        } else {
            try writeJPEG(from: source, to: partial)
        }
        return try finish(partial, as: output, contentType: contentType)
    }

    private func writeJPEG(from source: CGImageSource, to url: URL) throws {
        guard let image = ImageThumbnail.image(from: source, maxPixelSize: Self.maximumImagePixelSize) else {
            throw MediaError.unreadableImage
        }
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw MediaError.exportFailed("No JPEG encoder") }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaError.exportFailed("JPEG encoding failed")
        }
    }
}

/// Downscaled images for display. ImageIO decodes only what the size needs, so a tile never holds a
/// full-size photo in memory the way `NSImage(contentsOf:)` does.
public enum ImageThumbnail {
    /// The image in the file at `url`, upright and at most `maxPixelSize` on its long side (never upscaled); `nil`
    /// when it can't be read. Async so the decode runs off the caller's actor. `sending`: `CGImage` isn't `Sendable`.
    /// Any other URL gives `nil` without being opened: a picture a server links to is read with JobEngine's
    /// `ServerImageReader`, which checks the link, and decoded with `image(data:maxPixelSize:)`.
    public static func image(at url: URL, maxPixelSize: Int) async -> sending CGImage? {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(from: source, maxPixelSize: maxPixelSize)
    }

    /// The image encoded in `data`, as `image(at:maxPixelSize:)` gives it; the encoded bytes aren't cached.
    public static func image(data: Data, maxPixelSize: Int) async -> sending CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return image(from: source, maxPixelSize: maxPixelSize)
    }

    /// The upright size of the image in the file at `url`, read from its header: EXIF orientations 5–8 turn the
    /// image a quarter, so its sides swap. `nil` when it can't be read.
    public static func size(at url: URL) -> PixelSize? {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let size =
            (5...8).contains(orientation)
            ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
        return size.isValid ? size : nil
    }

    /// Whether the image in the file at `url` has an alpha channel, read from its header; `false` when unread.
    public static func hasAlpha(at url: URL) -> Bool {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    static func image(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
