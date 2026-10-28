import Foundation
import JutsuCore

public struct EngineSettings: Sendable, Hashable {
    /// Finished videos land here: the app passes the `Videos` folder of the output folder (`OutputSubfolder`).
    public var outputDirectory: URL
    /// Names each result when it is placed in `outputDirectory`.
    public var outputNamePattern: OutputNamePattern
    /// How many jobs may be submitted or running at once.
    public var maxConcurrency: Int
    /// Wait before the first poll and after every status change, in seconds. Higgsfield's polling guide:
    /// start at 2 s, grow by 1.5× up to 10 s.
    public var pollInitialDelay: TimeInterval
    /// The poll wait grows by 1.5× up to this, in seconds.
    public var pollMaxDelay: TimeInterval
    /// The wait a provider asks for between shared status calls (`BatchStatus.pollAfter`) is kept in this range,
    /// in seconds, so a server asking for 0 isn't hammered and one asking for an hour doesn't stall its jobs.
    public var serverPollDelay: ClosedRange<TimeInterval>
    /// Wait before the first retry of a failed step (network, 5xx, concurrency limit), in seconds.
    public var retryInitialDelay: TimeInterval
    /// The retry wait doubles up to this, in seconds; longer than polling, so an outage isn't hammered.
    public var retryMaxDelay: TimeInterval
    /// The wait a provider asks for before a refused step is sent again (`Retry-After` of a full queue) is kept in
    /// this range, in seconds, so a server asking for 0 isn't hammered and one asking for a day doesn't stall the job.
    public var serverRetryDelay: ClosedRange<TimeInterval>
    /// A job not yet submitted whose step has failed this long, in seconds, and at least `retryPauseFailures`
    /// times in a row, pauses (`keptFailing`) instead of retrying on. Both, so a Mac that slept through one
    /// wait doesn't pause a job on its next failure.
    public var retryPauseAfter: TimeInterval
    public var retryPauseFailures: Int
    /// Every wait is scaled by a random factor in `1 ± jitter`.
    public var jitter: Double
    /// Older uploads are uploaded again: the API doesn't document how long it keeps them. Seconds.
    public var uploadMaxAge: TimeInterval
    /// A submitted job still unfinished this long after submit fails, in seconds.
    public var generationDeadline: TimeInterval
    /// Larger downloads are refused, in bytes.
    public var maxDownloadBytes: Int64

    public init(
        outputDirectory: URL, outputNamePattern: OutputNamePattern = .standard, maxConcurrency: Int = 2,
        pollInitialDelay: TimeInterval = 2, pollMaxDelay: TimeInterval = 10,
        serverPollDelay: ClosedRange<TimeInterval> = 1...30, retryInitialDelay: TimeInterval = 5,
        retryMaxDelay: TimeInterval = 60, serverRetryDelay: ClosedRange<TimeInterval> = 1...600,
        retryPauseAfter: TimeInterval = 15 * 60, retryPauseFailures: Int = 5,
        jitter: Double = 0.2, uploadMaxAge: TimeInterval = 3600,
        generationDeadline: TimeInterval = 2 * 3600, maxDownloadBytes: Int64 = 4 << 30
    ) {
        self.outputDirectory = outputDirectory
        self.outputNamePattern = outputNamePattern
        self.maxConcurrency = maxConcurrency
        self.pollInitialDelay = pollInitialDelay
        self.pollMaxDelay = pollMaxDelay
        self.serverPollDelay = serverPollDelay
        self.retryInitialDelay = retryInitialDelay
        self.retryMaxDelay = retryMaxDelay
        self.serverRetryDelay = serverRetryDelay
        self.retryPauseAfter = retryPauseAfter
        self.retryPauseFailures = retryPauseFailures
        self.jitter = jitter
        self.uploadMaxAge = uploadMaxAge
        self.generationDeadline = generationDeadline
        self.maxDownloadBytes = maxDownloadBytes
    }
}

/// The engine's waits, from its settings.
extension Backoff {
    static func polling(_ settings: EngineSettings) -> Backoff {
        .polling(initial: settings.pollInitialDelay, maximum: settings.pollMaxDelay, jitter: settings.jitter)
    }

    static func retrying(_ settings: EngineSettings) -> Backoff {
        Backoff(
            initial: settings.retryInitialDelay, maximum: settings.retryMaxDelay, factor: 2, jitter: settings.jitter)
    }
}
