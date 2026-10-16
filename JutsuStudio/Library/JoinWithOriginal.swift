import AppKit
import JobEngine
import JutsuCore
import MediaKit
import Persistence
import Presentation
import UniformTypeIdentifiers

/// "Join with Original…" on an Extend result: asks where to save, then writes the source selection the job continued
/// followed by the new part as one MP4.
@MainActor
enum JoinWithOriginal {
    /// An Extend result with its file and a local source to put in front of it.
    static func isAvailable(for item: LibraryItemModel) -> Bool {
        item.spec.mode == .extend && item.outputFile != nil && item.spec.source?.fileURL.isFileURL == true
    }

    /// The alert to show when joining fails; `nil` when it worked or the user canceled the save panel.
    static func run(for item: LibraryItemModel, catalog: SwiftDataStore) async -> UserMessage? {
        guard let result = item.outputFile, let source = item.spec.source else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue =
            String(
                localized: "\(result.deletingPathExtension().lastPathComponent) joined",
                comment: "File name of an Extend result joined with its original, without the extension")
            + ".mp4"
        guard panel.runModal() == .OK, let output = panel.url else { return nil }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let title = String(localized: "Can't join the clips")
        do {
            let range = source.range
            try await source.withAccess { original in
                try await ClipJoiner.join(original, range: range, then: result, to: scratch)
            }
            try FileReplacement.move(scratch, to: output)
            try await catalog.saveJoinedVideo(
                from: item.job, output: output, bookmark: AppEnvironment.bookmark(for: output))
            return nil
        } catch is CancellationError {
            return nil
        } catch MediaError.exportFailed(let reason) {
            return UserMessage(title: title, message: reason)
        } catch {
            return UserMessage(title: title, message: error.localizedDescription)
        }
    }
}
