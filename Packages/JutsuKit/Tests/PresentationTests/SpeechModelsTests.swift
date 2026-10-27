import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// Keeps "downloaded" in memory: a download completes, or fails with `failure`.
final class FakeModelDownloader: SpeechModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false
    var failure: (any Error)?

    func isComplete(_ manifest: ModelManifest, in folder: URL) -> Bool { lock.withLock { complete } }

    func download(
        _ manifest: ModelManifest, into folder: URL, progress: @escaping @Sendable (Double) -> Void
    )
        async throws
    {
        progress(0.5)
        if let failure { throw failure }
        lock.withLock { complete = true }
        progress(1)
    }

    /// The current revision's folder takes 1000 bytes once downloaded; another folder takes what is in it.
    func size(of folder: URL) -> Int64 {
        guard folder.lastPathComponent.hasSuffix(String(ParakeetUltra.revision.prefix(8))) else {
            let files =
                (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.reduce(0) { $0 + Int64((try? Data(contentsOf: $1))?.count ?? 0) }
        }
        return lock.withLock { complete ? 1000 : 0 }
    }

    func remove(_ folder: URL) throws {
        try? FileManager.default.removeItem(at: folder)
        lock.withLock {
            if folder.lastPathComponent.hasSuffix(String(ParakeetUltra.revision.prefix(8))) { complete = false }
        }
    }
}

@MainActor
@Suite struct SpeechModelsTests {
    let downloader = FakeModelDownloader()
    let root = URL(filePath: "/tmp/speech-models")

    @Test func downloadsIntoAFolderOfItsRevisionAndRemoves() async {
        let models = SpeechModels(root: root, downloader: downloader)
        var changes = 0
        models.onChange = { changes += 1 }
        #expect(models.state == .notDownloaded)
        #expect(models.folder.lastPathComponent == "parakeet-ultra-\(ParakeetUltra.revision.prefix(8))")

        models.download()
        #expect(models.isDownloading)
        await models.finish()
        #expect(models.state == .ready)
        #expect(models.size == 1000)
        #expect(changes == 1)

        models.remove()
        #expect(models.state == .notDownloaded)
        #expect(models.size == 0)
        #expect(changes == 2)
    }

    @Test func aFailedDownloadSaysSo() async {
        downloader.failure = URLError(.notConnectedToInternet)
        let models = SpeechModels(root: root, downloader: downloader)

        models.download()
        await models.finish()

        #expect(models.state == .notDownloaded)
        #expect(models.failure?.title == SubtitleText.downloadFailedTitle)
    }

    @Test func aCanceledDownloadSaysNothing() async {
        downloader.failure = CancellationError()
        let models = SpeechModels(root: root, downloader: downloader)

        models.download()
        models.cancel()
        await models.finish()

        #expect(models.state == .notDownloaded)
        #expect(models.failure == nil)
    }

    @Test func anEarlierRevisionCountsUntilTheCurrentOneIsDownloaded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "parakeet-ultra-00000000", directoryHint: .isDirectory)
        let other = root.appending(path: "other-model", directoryHint: .isDirectory)
        for folder in [old, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 300).write(to: folder.appending(path: "weights.bin"))
        }

        let models = SpeechModels(root: root, downloader: downloader)
        #expect(models.size == 300)

        models.download()
        await models.finish()
        #expect(models.size == 1000)
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }

    @Test func removingAlsoRemovesEarlierRevisions() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "parakeet-ultra-00000000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(count: 300).write(to: old.appending(path: "weights.bin"))

        let models = SpeechModels(root: root, downloader: downloader)
        models.remove()
        #expect(models.size == 0)
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
    }
}
