import Foundation
import JobEngine
import JutsuCore
import Persistence
import Presentation

/// What the Settings page changes at runtime; the engine picks it up without a restart.
extension AppEnvironment {
    func setOutputFolder(_ folder: URL?) async throws {
        try outputFolder.use(folder)
        await engine.setOutputDirectory(outputFolder.url(of: .videos))
    }

    /// An empty or invalid pattern names results with the default one. Sent after the writes before it, so the last
    /// keystroke wins.
    func setOutputNamePattern(_ pattern: String) {
        writeSetting { await $0.setOutputNamePattern(OutputNamePattern(pattern)) }
    }

    /// Sent after the writes before it, so the last step wins.
    func setMaxConcurrency(_ limit: Int) {
        writeSetting { await $0.setMaxConcurrency(AppSettings.clampConcurrency(limit)) }
    }

    /// Runs `write` once every settings write before it has finished. Each change on its own `Task` could reach the
    /// engine in any order, and `setMaxConcurrency` waits inside the engine, so a stale value could land last.
    @discardableResult
    func writeSetting(_ write: @escaping @Sendable (JobEngine) async -> Void) -> Task<Void, Never> {
        let (previous, engine) = (settingsWrite, engine)
        let task = Task {
            await previous?.value
            await write(engine)
        }
        settingsWrite = task
        return task
    }

    func storageUsage() async throws -> StorageUsage {
        let materials = try await store.materials()
        let results = materials.filter { !$0.isHidden }.flatMap { $0.versions.compactMap(\.fileURL) }
        return await StorageUsage.measure(
            results: results, sources: layout.sourcesFolder, cache: layout.cacheFolder,
            media: layout.downloadedInputFolders)
    }

    func oldDrafts(olderThan days: Int) async throws -> [OldDraft] {
        try await OldDrafts.find(libraryJobs(), olderThan: days)
    }

    /// Moves the drafts' result files to the Trash; their records stay, so the library shows the files as missing.
    /// Returns the first error after trying every file.
    func trash(_ drafts: [OldDraft]) async throws {
        let files = drafts.map(\.file)
        try await Task.detached(priority: .utility) {
            var firstError: (any Error)?
            for file in files {
                do {
                    try FileLayout.moveToTrash(file)
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError { throw firstError }
        }.value
    }

    /// Deletes prepared sources, preset previews and downloaded Motion Library clips and uploads, then recreates
    /// the empty folders. The Create draft's files stay, so the form doesn't lose them. The view allows it only while
    /// no job is active.
    func clearCache() async throws {
        let (layout, kept) = (self.layout, navigation.draftFiles)
        try await Task.detached(priority: .utility) {
            try layout.clearCache(keeping: kept)
            try layout.prepareDirectories()
        }.value
    }

    /// Every finished job in the library and the reference image requests of the last 30 days, as CSV.
    func spendingCSV() async throws -> String {
        let jobs = try await store.finishedJobs()
        let images = imageSpend.charges
        return await Task.detached(priority: .userInitiated) { SpendingCSV.csv(jobs, images: images) }.value
    }

    /// Fetched and decoded on the store's actor, off the main one.
    private func libraryJobs() async throws -> [Job] {
        try await store.materials().filter { !$0.isHidden }.compactMap { $0.current.video }
    }
}
