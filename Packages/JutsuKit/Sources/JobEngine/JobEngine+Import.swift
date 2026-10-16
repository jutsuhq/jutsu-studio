import Foundation
import JutsuCore

extension JobEngine {
    /// Downloads the output of a generation made elsewhere into the output folder and saves `job`, a finished
    /// job from `Job(importing:)`, with it and the file's own length and frame size (`Job.outputMedia`): the provider's
    /// params for them are only a hint, and can be wrong. Importing a job that is already stored returns the stored one.
    /// A refusal worth waiting out (`fetchResult`) throws `ProviderError.server`; importing again resumes, until the
    /// next `start()` deletes the partial file.
    @discardableResult
    public func importFinished(_ job: Job, from url: URL) async throws -> Job {
        if let stored = try await repository.job(id: job.id) { return stored }
        importing.insert(job.id)
        defer { importing.remove(job.id) }
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
