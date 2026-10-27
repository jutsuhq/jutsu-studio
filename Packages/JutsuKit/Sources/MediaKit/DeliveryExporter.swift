import CoreGraphics
import Foundation
import ImageIO
import JutsuCore

/// Writes the files of a delivery set (`DeliveryPlan`): images with ImageIO, videos through `EditingExporter`.
public enum DeliveryExporter {
    /// Writes `task`'s file into `folder` from the item's file `source`, which is only read. The file, and the SRT and
    /// VTT of a video output with subtitle files, are written aside first and moved in together when all are complete;
    /// they replace existing files only when the set wrote them before (`DeliveryTask.replacesExisting`), and a failed
    /// or canceled export leaves the folder as it was. A video output with subtitles burns `subtitles` in, or writes
    /// them as SRT and VTT next to the video, timed as it is.
    /// - Parameter subtitles: the cues of the item's version; an output with subtitles throws
    ///   `DeliverySetError.noSubtitles` without them.
    /// - Returns: the written file.
    @discardableResult
    public static func export(
        _ task: DeliveryTask, source: URL, subtitles: [SubtitleCue]? = nil, into folder: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let cues = subtitles ?? []
        if task.output.kind == .video, task.output.subtitles != nil, cues.isEmpty {
            throw DeliverySetError.noSubtitles
        }
        let output = folder.appending(path: task.fileName, directoryHint: .notDirectory)
        let staging = stagingFile(in: folder, fileExtension: task.output.fileExtension)
        var staged = [(staging: staging, target: output)]
        defer { for file in staged { try? FileManager.default.removeItem(at: file.staging) } }
        switch task.output.preset {
        case .image(let preset):
            try writeImage(
                source, preset: preset, crop: task.output.aspect.map { ($0, task.frame ?? .centered) }, to: staging)
            progress(1)
        case .video(let preset):
            try await EditingExporter.export(
                source, source: nil, preset: preset, crop: task.output.aspect.map { ($0, task.frame ?? .centered) },
                burnIn: task.output.subtitles == .burnIn ? cues : [], to: staging, progress: progress)
        }
        for (name, format) in zip(
            DeliveryPlan.names(task.fileName, task.output).dropFirst(), task.output.subtitleFormats)
        {
            let file = stagingFile(in: folder, fileExtension: format.fileExtension)
            staged.append((file, folder.appending(path: name, directoryHint: .notDirectory)))
            try Data(format.text(of: cues).utf8).write(to: file)
        }
        try Task.checkCancellation()
        try moveIn(staged, replacing: task.replacesExisting)
        return output
    }

    private static func stagingFile(in folder: URL, fileExtension: String) -> URL {
        folder.appending(path: ".\(UUID().uuidString).partial", directoryHint: .notDirectory)
            .appendingPathExtension(fileExtension)
    }

    /// Moves every staged file to its name, or none: a name taken by a file the set didn't write fails before
    /// anything moves, and a move that fails takes back the files this export added.
    static func moveIn(_ staged: [(staging: URL, target: URL)], replacing: Bool) throws {
        let manager = FileManager.default
        let exists = { (url: URL) in manager.fileExists(atPath: url.path(percentEncoded: false)) }
        if !replacing, let taken = staged.first(where: { exists($0.target) }) {
            throw CocoaError(
                .fileWriteFileExists, userInfo: [NSFilePathErrorKey: taken.target.path(percentEncoded: false)])
        }
        var added: [URL] = []
        do {
            for file in staged {
                if replacing, exists(file.target) {
                    _ = try manager.replaceItemAt(file.target, withItemAt: file.staging)
                } else {
                    try manager.moveItem(at: file.staging, to: file.target)
                    added.append(file.target)
                }
            }
        } catch {
            for url in added { try? manager.removeItem(at: url) }
            throw error
        }
    }

    /// Decodes the image upright at full size, crops it, scales it down to the preset's long edge and writes it in
    /// the preset's format and color space. Formats without alpha are drawn over the preset's background.
    static func writeImage(
        _ source: URL, preset: ImageExportPreset, crop: (CropAspect, CropFrame)?, to output: URL
    ) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(imageSource) > 0
        else { throw MediaError.unreadableImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let longSide = max(
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        guard longSide > 0, let upright = ImageThumbnail.image(from: imageSource, maxPixelSize: longSide) else {
            throw MediaError.unreadableImage
        }
        let size = PixelSize(width: upright.width, height: upright.height)
        let rect =
            crop.map { aspect, frame in frame.rect(for: aspect, in: size) }
            ?? PixelRect(x: 0, y: 0, width: size.width, height: size.height)
        guard
            let cropped = upright.cropping(
                to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        else { throw MediaError.exportFailed("The crop lies outside the image") }
        let target = preset.outputSize(for: rect.size)
        let image = try render(cropped, size: target, preset: preset)
        guard
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, preset.format.typeIdentifier as CFString, 1, nil)
        else { throw MediaError.exportFailed("No \(preset.format.fileExtension.uppercased()) encoder") }
        var options: [CFString: Any] = [:]
        if preset.format.isLossy {
            options[kCGImageDestinationLossyCompressionQuality] = min(max(preset.quality, 0), 1)
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaError.exportFailed("\(preset.format.fileExtension.uppercased()) encoding failed")
        }
    }

    /// `image` drawn at `size` in the preset's color space, which converts its colors; with alpha only for PNG.
    private static func render(_ image: CGImage, size: PixelSize, preset: ImageExportPreset) throws -> CGImage {
        let name = preset.colorSpace == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        let keepsAlpha = preset.format.keepsAlpha
        let alpha: CGImageAlphaInfo = keepsAlpha ? .premultipliedLast : .noneSkipLast
        guard let space = CGColorSpace(name: name),
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: alpha.rawValue)
        else { throw MediaError.exportFailed("Can't draw a \(size.width) × \(size.height) image") }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if !keepsAlpha {
            let background = preset.background
            let components = [background.red, background.green, background.blue, 1].map { CGFloat($0) }
            if let color = CGColor(colorSpace: space, components: components) { context.setFillColor(color) }
            context.fill(bounds)
        }
        context.draw(image, in: bounds)
        guard let rendered = context.makeImage() else { throw MediaError.exportFailed("Can't draw the image") }
        return rendered
    }
}
