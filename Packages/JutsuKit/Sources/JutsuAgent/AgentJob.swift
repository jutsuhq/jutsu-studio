import Foundation

// What the video, image, jobs and job_action commands answer.

/// One piece of work, as an agent follows it with `jobs`: a video job, an image request, or an export (`kind`).
public struct AgentJob: Codable, Equatable, Sendable {
    public var id: UUID
    /// preparing, uploading, waiting_for_slot, queued, processing, downloading, paused, done, failed, rejected,
    /// canceled; unknown for an ID Jutsu Studio doesn't know (an export's, after a relaunch).
    public var state: String
    /// Why it is paused: agent_limit and price_above_cap wait for the person, by_user for Resume all.
    public var pauseReason: String?
    /// For agent_limit: unknown_price, over_max_cost, over_daily_budget, ledger_unavailable,
    /// unlimited_not_allowed or above_approved_price.
    public var hold: String?
    /// Only the person can move it on (a pause for a limit, the connection or funds).
    public var needsPerson: Bool
    /// 0…1 while preparing, uploading or downloading, and for an export the share of its files finished.
    public var progress: Double?
    public var price: AgentAmount?
    public var isPriceExact: Bool
    /// The provider charged, or may have.
    public var charged: Bool
    /// Why it failed, in the person's language.
    public var error: String?
    /// The finished video's path on the person's Mac, or an image request's first image.
    public var result: String?
    /// Every file the job made: an image request's images, an export's files written.
    public var results: [String]?
    /// "video", "image" for a create_image request, "export" or "delivery_export" for an export, "unknown".
    public var kind: String
    public var requestID: String?
    public var client: String?
    /// A video's or image's; nil for an export.
    public var mode: String?
    public var model: String?
    /// An export's folder.
    public var folder: String?
    /// An export's files so far, each done, failed or skipped.
    public var files: [AgentExportFile]?
    /// A delivery export's set.
    public var set: UUID?
    /// What to do about it: for state unknown; for a finished video, how to check it with `frames`; for a request
    /// sent again with a higher max_cost, why its job is still held.
    public var next: String?
    /// nil for state unknown.
    public var createdAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID, state: String, pauseReason: String? = nil, hold: String? = nil, needsPerson: Bool = false,
        progress: Double? = nil, price: AgentAmount? = nil, isPriceExact: Bool = false, charged: Bool = false,
        error: String? = nil, result: String? = nil, results: [String]? = nil, kind: String = "video",
        requestID: String? = nil, client: String? = nil, mode: String? = nil, model: String? = nil,
        folder: String? = nil, files: [AgentExportFile]? = nil, set: UUID? = nil, next: String? = nil,
        createdAt: Date?, finishedAt: Date? = nil
    ) {
        self.folder = folder
        self.files = files
        self.set = set
        self.next = next
        self.id = id
        self.state = state
        self.pauseReason = pauseReason
        self.hold = hold
        self.needsPerson = needsPerson
        self.progress = progress
        self.price = price
        self.isPriceExact = isPriceExact
        self.charged = charged
        self.error = error
        self.result = result
        self.results = results
        self.kind = kind
        self.requestID = requestID
        self.client = client
        self.mode = mode
        self.model = model
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, pauseReason, hold, needsPerson, progress, price, isPriceExact, charged, error, result
        case results, kind
        case requestID = "requestId"
        case client, mode, model, folder, files, set, next, createdAt, finishedAt
    }
}

extension AgentJob {
    /// This job as read again, keeping the `next` an earlier answer gave it while it still waits in the same state for
    /// the same reason: a raise of `max_cost` still held says why, and a `create_video` wait reads the job again.
    public func keepingNext(of earlier: AgentJob) -> AgentJob {
        guard next == nil, state == earlier.state, pauseReason == earlier.pauseReason, hold == earlier.hold else {
            return self
        }
        var job = self
        job.next = earlier.next
        return job
    }
}

public struct AgentCreated: Codable, Equatable, Sendable {
    public var requestID: String
    /// The request was known: these are the jobs it queued before, and nothing new was queued.
    public var known: Bool
    public var jobs: [AgentJob]
    /// The images a new request sent, in order, with the @ImageN tags its prompt names them by; left out for a known
    /// request and one without images.
    public var references: [AgentReference]?
    /// With `wait_seconds`: the wait ran out before every job's price was known or it was held; nothing was stopped.
    // swiftlint:disable:next discouraged_optional_boolean
    public var timedOut: Bool?

    public init(
        // swiftlint:disable:next discouraged_optional_boolean
        requestID: String, known: Bool, jobs: [AgentJob], references: [AgentReference]? = nil, timedOut: Bool? = nil
    ) {
        self.requestID = requestID
        self.known = known
        self.jobs = jobs
        self.references = references
        self.timedOut = timedOut
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case known, jobs, references, timedOut
    }
}

public struct AgentJobs: Codable, Equatable, Sendable {
    public var jobs: [AgentJob]
    /// The wait ran out before every job settled; nothing was stopped.
    public var timedOut: Bool
    /// Without ids: pass as `cursor` for the next, older page; nil on the last one.
    public var nextCursor: String?

    public init(jobs: [AgentJob], timedOut: Bool = false, nextCursor: String? = nil) {
        self.jobs = jobs
        self.timedOut = timedOut
        self.nextCursor = nextCursor
    }
}

public struct AgentActed: Codable, Equatable, Sendable {
    public var action: AgentJobAction
    /// The job as it is now, for an action on one.
    public var job: AgentJob?

    public init(action: AgentJobAction, job: AgentJob? = nil) {
        self.action = action
        self.job = job
    }
}
