import Foundation

/// One generation, from the moment it is queued until it is in the library.
/// The engine owns its lifecycle; a `JobRepository` persists it.
public struct Job: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var spec: JobSpec
    public var providerKind: ProviderKind
    /// `GenerationProvider.owner` of the connection that queued the job; only that connection may act on it.
    /// `nil` in jobs stored before this existed, which the engine assigns as it loads them.
    public var owner: String?
    /// The library item this job was made from ("Render final", "Edit & Re-run"); it may have been deleted
    /// since. `nil` for a job started from scratch and in jobs stored before this existed.
    public var parentID: UUID?
    /// Shared by the jobs of one batch (one range × several styles or character sets), which the queue and the
    /// library show as a group. `nil` for a job queued on its own and in jobs stored before batches existed.
    public var batchID: UUID?
    public var variantGroupID: UUID?
    public var state: JobState
    /// 0…1 within the current state; only preparing, uploading, processing and downloading report it.
    public var progress: Double
    /// Sent with every submit of one attempt: network retries, a lost submit response and resume
    /// after a crash reuse it, so they can't charge twice. A user retry of an uncharged `failed` or
    /// `canceled` job gets a new key, unless a submit of it may have reached the server: the old key
    /// then lets the provider return that request instead of charging for another.
    public var idempotencyKey: UUID
    /// The preliminary price, from the list price or the provider's estimate when the job was queued.
    public var cost: Cost
    /// What the provider quoted for the uploaded inputs right before submit; `nil` until then, or when it
    /// can't quote.
    public var serverPrice: Cost?
    /// A price the user agreed to over the daily cap: the estimate when queued, or a server price quoted later.
    public var approvedPrice: Cost?
    public var inputs: RemoteInputs?
    public var remote: RemoteJob?
    /// Saved right before a submit is sent, cleared once it is answered. Still set after a crash means
    /// the server may have the job; `nil` in jobs stored before this existed.
    public var submitAttempt: SubmitAttempt?
    public var outputFile: URL?
    /// The downloaded result's own length and frame size, read from the file. `nil` before the download, when the
    /// file can't be read, and in jobs stored before this existed.
    public var outputMedia: OutputMedia?
    /// The output folder the running download started in. Its partial file and the result stay there even if
    /// the output folder changes meanwhile, so the download resumes. `nil` while no download runs.
    public var downloadFolder: URL?
    /// When the API accepted the submit; `nil` before that and in jobs stored before this existed.
    public var submittedAt: Date?
    /// When the API first reported the job in progress; `nil` if no poll saw that state.
    public var processingAt: Date?
    /// When the user moved the job ahead of the other jobs waiting for a slot (Run next).
    public var promotedAt: Date?
    /// When the API finished the generation, which is when it charges. Set even if the download is
    /// later canceled or fails; `nil` in jobs stored before this existed.
    public var chargedAt: Date?
    /// When the deadline failed the job while the provider could still finish, and charge for, its generation;
    /// `nil` otherwise.
    public var timedOutAt: Date?
    /// When the user last asked to check a job past its deadline again; its deadline counts from here then.
    public var checkedAgainAt: Date?
    public let createdAt: Date
    /// When the last Retry began a new attempt; `nil` before one and in jobs stored before this existed.
    public var retriedAt: Date?
    /// Why moderation refused the job; `nil` for any other job, and in rejected jobs stored before this existed.
    public var rejection: Rejection?
    public var finishedAt: Date?
    /// When a generation made outside this app was added to the library; `nil` for jobs the app ran.
    public var importedAt: Date?
    /// The step that keeps failing and waits to run again; `nil` once a step gets through, and in jobs stored
    /// before this existed. Kept on a job paused for `keptFailing`, for what it failed with.
    public var retrying: RetryStatus?
    /// The result's virality prediction, kept so it isn't paid for again; `nil` until scored, and in jobs stored
    /// before this existed. Only set on a finished job, which the engine no longer saves.
    public var virality: ViralityScore?
    /// Variants its submit asked for (`JobSpec.variants`) that the answer started no job for; `nil` when it started
    /// them all, and in jobs stored before variants existed. Set on the job that sent the submit.
    public var missingVariants: Int?

    public init(
        id: UUID = UUID(), spec: JobSpec, providerKind: ProviderKind, owner: String? = nil, parentID: UUID? = nil,
        batchID: UUID? = nil, cost: Cost, idempotencyKey: UUID = UUID(), createdAt: Date = Date()
    ) {
        self.id = id
        self.spec = spec
        self.providerKind = providerKind
        self.owner = owner
        self.parentID = parentID
        self.batchID = batchID
        self.state = .preparing
        self.progress = 0
        self.idempotencyKey = idempotencyKey
        self.cost = cost
        self.createdAt = createdAt
    }

    /// The API finished the generation and charged for it, so its result can be fetched again.
    public var hasPaidOutput: Bool { chargedAt != nil && remote != nil }

    /// Failed at the deadline with its request still known: the provider may yet finish it and charge for it,
    /// so it is checked again rather than submitted again.
    public var mayStillFinish: Bool {
        state == .failed(reason: .deadline) && remote != nil && chargedAt == nil
    }

    /// Failed without knowing whether the provider charged for it: past the deadline (`mayStillFinish`), or with a
    /// submit that may have reached the server and was never answered (`submitAttempt` kept).
    public var mayHaveBeenCharged: Bool {
        guard case .failed = state, chargedAt == nil else { return false }
        return mayStillFinish || submitAttempt != nil
    }

    /// The API charges when it finishes a generation, so a job whose download then failed or was canceled
    /// is charged too. Jobs stored before `chargedAt` existed are charged when they are done.
    public var isCharged: Bool { state == .done || chargedAt != nil }

    /// How long the result runs: the file's own length once read, else what the job asked for (`JobSpec.duration`).
    /// A provider's job may not run as long as it asked (a Seedance Edit asked 5 s and ran 3.71 s).
    public var outputDuration: TimeInterval { outputMedia?.duration ?? spec.duration }

    /// The result's frame size: the file's own once read, else the source's; `nil` while neither is known.
    public var outputPixelSize: PixelSize? {
        if let size = outputMedia?.pixelSize { return size }
        return spec.source.map(\.pixelSize).flatMap { $0.isValid ? $0 : nil }
    }

    /// The best known price: the server's once it quoted one, the preliminary one before.
    public var price: Cost { serverPrice ?? cost }

    /// When the current attempt began: the last Retry, or when the job was queued.
    public var attemptStartedAt: Date { retriedAt ?? createdAt }

    /// From queueing, or the last Retry, until the API started generating, in seconds; `nil` until it started.
    public var queueWait: TimeInterval? {
        processingAt.map { $0.timeIntervalSince(attemptStartedAt) }
    }

    /// From the start of the generation until the API finished it, in seconds; `nil` unless both are known.
    public var processingTime: TimeInterval? {
        guard let processingAt, let chargedAt else { return nil }
        return chargedAt.timeIntervalSince(processingAt)
    }
}

/// What a downloaded result's file holds, read from the file itself rather than from what the job asked for.
public struct OutputMedia: Codable, Sendable, Hashable {
    /// In seconds.
    public var duration: TimeInterval
    /// Upright, as the file shows (its rotation applied).
    public var pixelSize: PixelSize

    public init(duration: TimeInterval, pixelSize: PixelSize) {
        self.duration = duration
        self.pixelSize = pixelSize
    }
}

/// A step of a job that failed for a reason waiting can fix, and is tried again with backoff.
public struct RetryStatus: Codable, Sendable, Hashable {
    /// What the last attempt failed with.
    public enum Cause: Codable, Sendable, Hashable {
        case network
        case server(status: Int)
        case modelUnavailable
        /// All of the account's slots are busy.
        case concurrencyLimit
        /// Out of funds after submit, while the job is polled or downloaded.
        case insufficientFunds
    }

    /// Failed attempts in a row, 1 after the first.
    public var failures: Int
    /// When the first of them failed.
    public var since: Date
    /// When the step runs again.
    public var nextAttemptAt: Date
    public var cause: Cause

    public init(failures: Int, since: Date, nextAttemptAt: Date, cause: Cause) {
        self.failures = failures
        self.since = since
        self.nextAttemptAt = nextAttemptAt
        self.cause = cause
    }
}

/// A submit that was sent and not yet answered.
public struct SubmitAttempt: Codable, Sendable, Hashable {
    /// The provider sent the job's idempotency key, so sending the submit again can't charge twice.
    public var isIdempotent: Bool

    public init(isIdempotent: Bool) {
        self.isIdempotent = isIdempotent
    }
}
