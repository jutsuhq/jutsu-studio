import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import JutsuCore
import UniformTypeIdentifiers

extension SuperResolutionRenderer {
    /// Upscale › On this Mac for an image up to 1920×1080 (`OnDeviceUpscale.offersImage`): 4× larger, or scaled down
    /// from that to `target`, and upright, in the source's file type when ImageIO can write it, else PNG. The result is opaque, which the sheet says for an
    /// image with transparency (`ImageThumbnail.hasAlpha`).
    // note: the result is opaque and 8 bits a channel; transparency or 16-bit depth would need the alpha scaled
    // apart and a deeper destination format.
    static func renderImage(
        source url: URL, to output: URL, scaler: some FrameScaling, target: OnDeviceUpscale.Target = .full,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput {
        guard let size = ImageThumbnail.size(at: url), OnDeviceUpscale.offersImage(size) else {
            throw MediaError.engineUnavailable
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
            let picture = ImageThumbnail.image(from: imageSource, maxPixelSize: max(size.width, size.height)),
            let space = picture.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil })
                ?? CGColorSpace(name: CGColorSpace.sRGB)
        else { throw MediaError.unreadableImage }
        let upright = PixelSize(width: picture.width, height: picture.height)
        let scale = OnDeviceUpscale.scale
        let scaledSize = PixelSize(width: upright.width * scale, height: upright.height * scale)
        guard let outputSize = target.output(for: upright) else { throw Self.targetNotLarger }

        let format = try await scaler.start(size: upright) { progress(.downloadingModel($0)) }
        defer { scaler.end() }
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = try FramePool(size: upright, attributes: format.source).make()
        context.render(
            CIImage(cgImage: picture), to: input,
            bounds: CGRect(x: 0, y: 0, width: upright.width, height: upright.height), colorSpace: space)
        let scaledBuffer = try FramePool(size: scaledSize, attributes: format.destination).make()
        try Task.checkCancellation()
        try await scaler.scale(
            TimedFrame(buffer: input, time: .zero), previous: nil, into: TimedFrame(buffer: scaledBuffer, time: .zero))
        try Task.checkCancellation()

        let scaled = Self.resized(
            CIImage(cvPixelBuffer: scaledBuffer, options: [.colorSpace: space]), from: scaledSize, to: outputSize)
        let bounds = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        guard
            let result = context.createCGImage(
                scaled.settingAlphaOne(in: bounds), from: bounds, format: .RGBA8, colorSpace: space)
        else { throw MediaError.exportFailed("Can't draw the upscaled image") }
        let type = writableType(of: imageSource)
        try write(result, as: type, to: output)
        progress(.working(1))
        return OnDeviceOutput(pixelSize: outputSize, duration: 0, fileExtension: fileExtension(of: type))
    }

    /// The 4× picture scaled down to `size` with Lanczos, the edge pixels repeated so the border stays sharp; as it is
    /// when `size` is the 4× one.
    private static func resized(_ image: CIImage, from scaled: PixelSize, to size: PixelSize) -> CIImage {
        guard size != scaled else { return image }
        let scale = Double(size.height) / Double(scaled.height)
        let aspect = Double(size.width) / (Double(scaled.width) * scale)
        return image.clampedToExtent()
            .applyingFilter(
                "CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: aspect]
            )
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    /// "jpg" for JPEG, as the library names it, else the type's own: "png", "heic".
    static func fileExtension(of type: UTType) -> String {
        type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "png"
    }

    /// The source's own type when ImageIO writes it, else PNG.
    private static func writableType(of source: CGImageSource) -> UTType {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard let identifier = CGImageSourceGetType(source) as String?, writable.contains(identifier),
            let type = UTType(identifier)
        else { return .png }
        return type
    }

    private static func write(_ image: CGImage, as type: UTType, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw MediaError.exportFailed("No \(type.preferredFilenameExtension ?? "image") encoder") }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaError.exportFailed("Can't write the upscaled image")
        }
    }
}
