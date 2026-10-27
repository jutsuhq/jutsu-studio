import Foundation
import JutsuCore
import MediaKit
import ParakeetKit
import Persistence
import Presentation

/// Subtitles made on this Mac (`SubtitleRuns`): the speech models hear the file, the catalog keeps the subtitles on
/// the version they were made from.
extension AppEnvironment {
    /// The runs, and Parakeet Ultra's folder in the app's container, which only Settings downloads into.
    static func subtitleRuns(
        store: SwiftDataStore, layout: FileLayout, defaults: UserDefaults
    ) -> (SubtitleRuns, SpeechModels) {
        let downloader = ModelDownloader()
        let models = SpeechModels(
            root: layout.root.appending(path: "Speech Models", directoryHint: .isDirectory), downloader: downloader)
        let folder = models.folder
        let parakeet = ParakeetEngine(folder: folder) { downloader.isComplete(ParakeetUltra.manifest, in: folder) }
        let speech = OnDeviceSpeech(
            cacheFolder: layout.cacheFolder.appending(path: "transcripts", directoryHint: .isDirectory),
            hashes: FileHashCache(storeURL: layout.cacheFolder.appending(path: "transcript-hashes.json")),
            parakeet: parakeet)
        let runs = SubtitleRuns(
            engine: speech, defaults: defaults,
            access: { file, bookmark, hear in
                try await SecurityScopedAccess.withAccess(to: file, bookmark: bookmark, hear)
            }
        ) { request, subtitles in
            // Not onto a version deleted meanwhile: that throws, and the run fails.
            try await store.setSubtitles(subtitles, for: request.source)
        }
        models.onChange = { [weak runs] in Task { await runs?.loadAvailability() } }
        return (runs, models)
    }

    /// The Subtitles sheet's target for the item's current version, with its file on this Mac; `nil` for an item
    /// that is gone, an image, or one whose file isn't here.
    func subtitleTarget(for item: LibraryItemModel) async -> SubtitleTarget? {
        guard !item.needsImport, let material = try? await store.material(id: item.id), material.kind == .video,
            let file = material.current.fileURL ?? item.outputFile
        else { return nil }
        return SubtitleTarget(
            source: material.reference, file: file, bookmark: material.current.bookmark, title: item.title)
    }

    func openSubtitles(for item: LibraryItemModel) async {
        guard let target = await subtitleTarget(for: item) else { return }
        navigation.subtitlesSheet = target
    }
}
