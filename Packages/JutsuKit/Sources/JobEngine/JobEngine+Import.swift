import Foundation
import JutsuCore

extension JobEngine {
    /// Downloads the output of a generation made elsewhere into the output folder and saves `job`, a finished
    /// job from `Job(importing:)`, with it and the file's own length and frame size (`Job.outputMedia`): the provider's
    /// params for them are only a hint, and can be wrong. Importing a job that is already stored returns the stored one,
    /// and importing one whose import is still running waits for that one instead of downloading it a second time.
    /// A refusal worth waiting out (`fetchResult`) throws `ProviderError.server`; importing again resumes, until the
    /// next `start()` deletes the partial file. Cancelling the import that started the download cancels it.
    @discardableResult
    public func importFinished(_ job: Job, from url: URL) async throws -> Job {
        if let running = importing[job.id] { return try await running.value }
        if let stored = try await repository.job(id: job.id) { return stored }
        // Another import may have started while the store was read.
        if let running = importing[job.id] { return try await running.value }
        let task = Task { try await self.fetchImport(job, from: url) }
        importing[job.id] = task
        defer { importing[job.id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func fetchImport(_ job: Job, from url: URL) async throws -> Job {
        try await waitUntilOnline()
        let folder = settings.outputDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = Self.partialFile(of: job.id, in: folder)
        try await fetchResult(url, to: partial, finishedAt: job.chargedAt)
        var imported = job
        let file = try placeResult(partial, of: job, in: folder)
        imported.outputFile = file
        imported.outputMedia = await media.outputMedia(of: file)
        try await repository.save(imported)
        return imported
    }
}
