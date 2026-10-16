import AppKit
import JobEngine
import MediaKit
import Presentation
import UniformTypeIdentifiers

/// "Export short preview": asks where to save, then writes the first seconds of a result as a small silent MP4.
@MainActor
enum ShortPreviewExport {
    /// The alert to show when the export fails; `nil` when it worked or the user canceled the save panel.
    static func run(for result: URL) async -> UserMessage? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = ShortPreview.fileName(for: result)
        guard panel.runModal() == .OK, let output = panel.url else { return nil }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let info = try await MediaProbe.probe(result)
            guard let range = ShortPreview.timeRange(duration: info.duration),
                let size = ShortPreview.renderSize(for: info.pixelSize)
            else { throw MediaError.unsupportedFormat }
            try await PreviewExport.export(
                result, range: range, renderSize: size, byteLimit: ShortPreview.byteLimit, to: scratch)
            try FileReplacement.move(scratch, to: output)
            return nil
        } catch is CancellationError {
            return nil
        } catch MediaError.exportFailed(let reason) {
            return UserMessage(title: String(localized: "Can't export the preview"), message: reason)
        } catch {
            return UserMessage(
                title: String(localized: "Can't export the preview"), message: error.localizedDescription)
        }
    }
}
