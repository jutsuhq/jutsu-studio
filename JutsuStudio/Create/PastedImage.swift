import AppKit
import Foundation

extension AppEnvironment {
    /// The clipboard's image as a PNG file of its own in `pasted/`, so it becomes a reference like a picked file.
    /// Clear Cache removes these files with the other downloaded inputs.
    func savePastedImage(from pasteboard: NSPasteboard) throws -> URL {
        guard let data = pasteboard.data(forType: .png) ?? Self.pngData(NSImage(pasteboard: pasteboard)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let folder = layout.pastedImagesFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Pasted \(UUID().uuidString).png", directoryHint: .notDirectory)
        try data.write(to: file, options: .atomic)
        return file
    }

    private static func pngData(_ image: NSImage?) -> Data? {
        guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
