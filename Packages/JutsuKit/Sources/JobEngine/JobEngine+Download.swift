import Foundation
import HiggsfieldCore
import JutsuCore

// A finished job's result on its way into the output folder, with its sound put back as the job asks.
extension JobEngine {
    func download(_ job: Job) async throws {
        let url: URL
        if let known = videoURLs[job.id] {
            url = known
        } else {
            // After a relaunch or a retry: the status call returns the URL again, until the result expires.
            let status: RemoteStatus
            do {
                status = try await remoteStatus(of: job)
            } catch ProviderError.validation {
                throw FailureReason.outputUnavailable
            }
            guard case .completed(let remoteURL) = status else { throw FailureReason.outputUnavailable }
            url = remoteURL
        }
        try await waitUntilOnline()
        let folder = job.downloadFolder ?? settings.outputDirectory
        if job.downloadFolder == nil { try await save(job.id) { $0.downloadFolder = folder } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = Self.partialFile(of: job.id, in: folder)
        do {
            try await fetchResult(url, to: partial, finishedAt: job.chargedAt)
        } catch ProviderError.server(status: 403) {
            // A signed URL that expired: the next try asks the status call for a fresh one.
            videoURLs[job.id] = nil
            throw ProviderError.server(status: 403)
        }
        // An operation's result keeps the sound the server gave it, in the container it came in, unless the server
        // drops the sound (`PostAction.restoresSourceSound`): it is put back as for a generation, in an MP4.
        let restoresSound = job.spec.operation?.action.restoresSourceSound ?? true
        let finished = restoresSound ? try await restoringAudio(of: job, in: partial) : partial
        let destination = try placeResult(
            finished, of: job, in: folder,
            fileExtension: job.spec.operation == nil || finished != partial
                ? nil : OutputNamePattern.resultExtension(of: url))
        if finished != partial { try? FileManager.default.removeItem(at: partial) }
        // What the job asked for isn't always what came back (a Seedance Edit ran shorter), so the file is read.
        let outputMedia = await media.outputMedia(of: destination)
        try await record(.downloaded, to: job.id) {
            $0.outputFile = destination
            $0.outputMedia = outputMedia
            $0.progress = 1
        }
    }

    /// How long Higgsfield keeps a finished result, in seconds.
    static let resultLifetime: TimeInterval = 7 * 24 * 3600

    /// Downloads a finished result into `partial`. A refusal that waiting can fix throws `ProviderError.server`
    /// and keeps the partial file, so the runner retries with backoff and resumes: 408, 429, and 403 while the
    /// result is younger than `resultLifetime` (a signed URL that expired). Any other refusal removes the partial
    /// file; 404, 410 and an old 403 mean the result expired.
    /// - Parameter finishedAt: when the generation finished; `nil` when unknown, which counts as fresh.
    func fetchResult(_ url: URL, to partial: URL, finishedAt: Date?) async throws {
        do {
            try await downloader.download(url, to: partial)
        } catch JobEngineError.downloadFailed(let status) {
            let isFresh = finishedAt.map { clock.now.timeIntervalSince($0) < Self.resultLifetime } ?? true
            switch status {
            case 408, 429:
                throw ProviderError.server(status: status)
            case 403 where isFresh:
                throw ProviderError.server(status: status)
            case 403, 404, 410:
                try? FileManager.default.removeItem(at: partial)
                throw FailureReason.outputUnavailable
            default:
                try? FileManager.default.removeItem(at: partial)
                throw ProviderError.validation(field: nil, message: Self.downloadRefusedReason(status))
            }
        } catch JobEngineError.downloadRefused(let reason) {
            try? FileManager.default.removeItem(at: partial)
            throw ProviderError.validation(field: nil, message: reason.message)
        }
    }

    static func downloadRefusedReason(_ status: Int) -> String {
        String(
            localized: "Higgsfield refused to send the result (HTTP \(status)). Retry to download it again.",
            bundle: .module)
    }

    /// The result with its sound as the job asks, or `partial` itself when nothing changes. Failing to
    /// add the sound keeps the silent result: the generation is paid for and still usable.
    private func restoringAudio(of job: Job, in partial: URL) async throws -> URL {
        let output = Self.audioFile(of: job.id, in: partial.deletingLastPathComponent())
        do {
            return try await media.restoreAudio(of: job.spec, result: partial, to: output) ? output : partial
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where Self.isOutOfSpace(error) {
            // Pauses the job, so the sound is still added once there is space again.
            throw error
        } catch {
            log.error("Job \(job.id): kept the result without source audio", detail: String(describing: error))
            return partial
        }
    }

    /// The partial file of the job's download: in the folder the download started in, or the output folder before
    /// one starts.
    func partialDownload(of id: UUID) -> URL {
        Self.partialFile(of: id, in: jobs[id]?.downloadFolder ?? settings.outputDirectory)
    }

    /// Moves a finished result into `directory` under the job's name, next to any file already there.
    /// - Parameter fileExtension: the result's own extension; `nil` for `OutputNamePattern.fileExtension`.
    func placeResult(_ file: URL, of job: Job, in directory: URL, fileExtension: String? = nil) throws -> URL {
        let name = settings.outputNamePattern.fileName(
            for: job, presetName: job.spec.presetID.flatMap(presetName), fileExtension: fileExtension)
        let free = OutputNamePattern.available(name) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return try Self.place(file, at: directory.appendingPathComponent(free))
    }

    /// Moves the finished download to `destination`. An earlier file there stays until the swap succeeds.
    static func place(_ partial: URL, at destination: URL) throws -> URL {
        try FileReplacement.move(partial, to: destination)
        return destination
    }
}
