import Foundation

// The video commands quote and create_video, and what the video commands answer (jobs and job_action are in
// AgentJobCommands.swift).

/// An amount in whole units of what the connection pays with: cents with an API key, credits on an account.
public struct AgentAmount: Codable, Equatable, Hashable, Sendable {
    public var amount: Int
    public var unit: AgentBudgetUnit

    public init(_ amount: Int, _ unit: AgentBudgetUnit) {
        self.amount = amount
        self.unit = unit
    }

    /// The largest amount an agent can name: $10 000 or 10 000 000 credits, the most a daily budget can be.
    public static func maximum(for unit: AgentBudgetUnit) -> Int {
        unit == .usdCents ? 1_000_000 : 10_000_000
    }

    private enum CodingKeys: String, CodingKey {
        case amount, unit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unit = try container.decode(AgentBudgetUnit.self, forKey: .unit)
        amount = try container.decode(Int.self, forKey: .amount)
        guard (0...Self.maximum(for: unit)).contains(amount) else {
            throw AgentError.badRequest("amount is 0 to \(Self.maximum(for: unit)) \(unit.rawValue)")
        }
    }
}

/// The source clip of a video: a file in the inbox for `create_video`; for `quote` only its length counts, so it
/// may come without a file.
public struct AgentSource: Codable, Equatable, Hashable, Sendable {
    /// For `create_video`: the clip's path in the app's inbox, from an upload.
    public var path: String?
    /// Seconds from the start of the file; 0 when left out.
    public var start: Double?
    /// Where the job's range ends, in seconds; left out, the whole clip from `start` up to the model's longest.
    public var end: Double?

    public init(path: String? = nil, start: Double? = nil, end: Double? = nil) {
        self.path = path
        self.start = start
        self.end = end
    }

    /// The longest file any model is asked about: 24 hours.
    public static let maxSeconds: Double = 86_400

    private enum CodingKeys: String, CodingKey {
        case path, start, end
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        start = try container.decodeIfPresent(Double.self, forKey: .start)
        end = try container.decodeIfPresent(Double.self, forKey: .end)
        if let problem = Self.problem(start: start, end: end) { throw AgentError.badRequest(problem) }
        if let path, !AgentVideoRequest.isValidPath(path) { throw AgentError.badRequest("source.path is a file path") }
    }

    /// Why these seconds can't be a range; checked before anything formats or computes with them.
    public static func problem(start: Double?, end: Double?) -> String? {
        for (name, value) in [("start", start), ("end", end)] {
            if let value, !(value.isFinite && (0...maxSeconds).contains(value)) {
                return "source.\(name) is a number of seconds from 0 to \(Int(maxSeconds))"
            }
        }
        if let start, let end, end <= start { return "source.end comes after source.start" }
        return nil
    }
}

/// The video an agent asks for, as `quote` and `create_video` take it. The app makes it into the same job the Create
/// form would, checked by the same rules and the model's limits.
public struct AgentVideoRequest: Codable, Equatable, Hashable, Sendable {
    /// The names agents use for the modes.
    public static let modes = ["motion_transfer", "restyle", "object_swap", "edit", "extend"]
    public static let audioOptions = ["original", "mute", "fade_out", "generated"]
    /// A sanity bound of the protocol only, above every model's own limit: the limit a request meets is the model's
    /// in its mode (`capabilities` model details `maxImages`, `quote` `maxImages`), from the server's constraints
    /// where they state one, which the app's own rules refuse the rest by with a reason.
    public static let protocolMaxImages = 16
    public static let maxVariants = 16
    /// Seconds a clip made without a source may be asked to run, or Extend to add.
    public static let maxLength: Double = 600
    /// A bound of the protocol only: the app keeps the first 80 characters of a title (`JobSpec.maxTitleLength`).
    public static let maxTitleLength = 1_000
    /// In Unicode scalars, as Create counts a prompt; `create_image` takes the same.
    public static let maxPromptLength = 10_000

    public var mode: String
    /// A model ID from `capabilities`; left out, the mode's default model.
    public var model: String?
    public var prompt: String?
    public var source: AgentSource?
    /// For `create_video`: the reference images' paths in the app's inbox, in order.
    public var images: [String]
    /// For `quote`: how many reference images there will be.
    public var imageCount: Int?
    /// Restyle's style, by its ID.
    public var style: UUID?
    public var resolution: String?
    /// A cheaper, lower resolution preview on a model that has drafts.
    public var draft: Bool
    /// Seconds a clip without a source runs, or Extend adds.
    public var length: Double?
    /// The frame of a clip without a source: "16:9", "9:16", "1:1"…
    public var aspectRatio: String?
    public var audio: String?
    /// Videos one submit makes, on a connection that offers more than one.
    public var variants: Int?
    /// The account's reference elements by name (`elements`): their images go first, before `images`.
    public var elements: [String]
    /// What the Queue, the Library and export names call the job instead of the source's file name.
    public var title: String?

    public init(
        mode: String, model: String? = nil, prompt: String? = nil, source: AgentSource? = nil, images: [String] = [],
        imageCount: Int? = nil, style: UUID? = nil, resolution: String? = nil, draft: Bool = false,
        length: Double? = nil, aspectRatio: String? = nil, audio: String? = nil, variants: Int? = nil,
        elements: [String] = [], title: String? = nil
    ) {
        self.mode = mode
        self.model = model
        self.prompt = prompt
        self.source = source
        self.images = images
        self.imageCount = imageCount
        self.style = style
        self.resolution = resolution
        self.draft = draft
        self.length = length
        self.aspectRatio = aspectRatio
        self.audio = audio
        self.variants = variants
        self.elements = elements
        self.title = title
    }

    /// How many reference images the job has: the files, else the count a quote names.
    public var referenceCount: Int { images.isEmpty ? (imageCount ?? 0) : images.count }

    private enum CodingKeys: String, CodingKey {
        case mode, model, prompt, source, images, imageCount, style, resolution, draft, length, aspectRatio, audio
        case variants, elements, title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        source = try container.decodeIfPresent(AgentSource.self, forKey: .source)
        images = try container.decodeIfPresent([String].self, forKey: .images) ?? []
        imageCount = try container.decodeIfPresent(Int.self, forKey: .imageCount)
        style = try container.decodeIfPresent(UUID.self, forKey: .style)
        resolution = try container.decodeIfPresent(String.self, forKey: .resolution)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        length = try container.decodeIfPresent(Double.self, forKey: .length)
        aspectRatio = try container.decodeIfPresent(String.self, forKey: .aspectRatio)
        audio = try container.decodeIfPresent(String.self, forKey: .audio)
        variants = try container.decodeIfPresent(Int.self, forKey: .variants)
        elements = try container.decodeIfPresent([String].self, forKey: .elements) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
        if let problem { throw AgentError.badRequest(problem) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(source, forKey: .source)
        if !images.isEmpty { try container.encode(images, forKey: .images) }
        try container.encodeIfPresent(imageCount, forKey: .imageCount)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encodeIfPresent(resolution, forKey: .resolution)
        if draft { try container.encode(draft, forKey: .draft) }
        try container.encodeIfPresent(length, forKey: .length)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(audio, forKey: .audio)
        try container.encodeIfPresent(variants, forKey: .variants)
        if !elements.isEmpty { try container.encode(elements, forKey: .elements) }
        try container.encodeIfPresent(title, forKey: .title)
    }

    /// Why the fields can't be a request, before the app's own rules; nil when they can. Shared by the helper, which
    /// checks before it reads any file, and the app.
    public var problem: String? {
        guard Self.modes.contains(mode) else { return "mode is one of \(Self.modes.joined(separator: ", "))" }
        if let model, !AgentNames.isValidModelID(model) { return "model is a model ID from capabilities" }
        if let prompt, prompt.unicodeScalars.count > Self.maxPromptLength {
            return "prompt is at most \(AgentNames.spaced(Self.maxPromptLength)) characters"
        }
        if let title, title.unicodeScalars.count > Self.maxTitleLength {
            return "title is at most \(AgentNames.spaced(Self.maxTitleLength)) characters"
        }
        if images.count > Self.protocolMaxImages {
            return "images takes at most \(Self.protocolMaxImages) files, more than any model takes"
        }
        if let path = images.first(where: { !Self.isValidPath($0) }) {
            return "images has a path that isn't one: \(path.prefix(80))"
        }
        if let imageCount, !(0...Self.protocolMaxImages).contains(imageCount) {
            return "image_count is 0 to \(Self.protocolMaxImages)"
        }
        if let problem = AgentElementNames.problem(elements) { return problem }
        if let length, !(length.isFinite && length > 0 && length <= Self.maxLength) {
            return "length is a number of seconds above 0 and up to \(Int(Self.maxLength))"
        }
        if let variants, !(1...Self.maxVariants).contains(variants) { return "variants is 1 to \(Self.maxVariants)" }
        if let audio, !Self.audioOptions.contains(audio) {
            return "audio is one of \(Self.audioOptions.joined(separator: ", "))"
        }
        if let resolution, resolution.utf8.count > 16 { return "resolution is one from capabilities, such as 720p" }
        if let aspectRatio, aspectRatio.utf8.count > 16 { return "aspect_ratio is a ratio such as 16:9" }
        return nil
    }

    static func isValidPath(_ path: String) -> Bool {
        (1...4096).contains(path.utf8.count) && !path.contains("\0")
    }
}

public struct QuoteCommand: Codable, Equatable, Sendable {
    public var video: AgentVideoRequest

    public init(video: AgentVideoRequest) {
        self.video = video
    }
}

/// Queues one video. The same `request_id` with the same parameters returns the job it queued before, however often
/// it is sent; with other parameters it is refused with `request_conflict`.
public struct CreateVideoCommand: Codable, Equatable, Sendable {
    public var requestID: String
    /// `AgentFingerprint` of the request as the agent sent it: the parameters, the agent's own paths and the files'
    /// sizes. The uploads of the request carry the same one.
    public var fingerprint: String
    /// The same digest without `max_cost`: what tells the request sent again with another `max_cost`, which may lift
    /// its job's hold over the old one. `nil` from a helper older than it.
    public var parameters: String?
    public var video: AgentVideoRequest
    /// The most the agent agrees to pay for the job; the app pauses it for the person when the price is above.
    public var maxCost: AgentAmount
    /// How long to wait, up to `JobsCommand.maxWaitSeconds`, until the job's price is known or it is held before
    /// answering. Not part of the request: a retry with another wait is the same request.
    public var waitSeconds: Int

    public init(
        requestID: String, fingerprint: String, parameters: String? = nil, video: AgentVideoRequest,
        maxCost: AgentAmount, waitSeconds: Int = 0
    ) {
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.parameters = parameters
        self.video = video
        self.maxCost = maxCost
        self.waitSeconds = waitSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case fingerprint, parameters, video, maxCost, waitSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        parameters = try container.decodeIfPresent(String.self, forKey: .parameters)
        video = try container.decode(AgentVideoRequest.self, forKey: .video)
        maxCost = try container.decode(AgentAmount.self, forKey: .maxCost)
        waitSeconds = try container.decodeIfPresent(Int.self, forKey: .waitSeconds) ?? 0
        guard AgentNames.isValidRequestID(requestID) else { throw AgentError.badRequest(AgentNames.requestIDRule) }
        guard AgentNames.isValidFingerprint(fingerprint), parameters.map(AgentNames.isValidFingerprint) ?? true else {
            throw AgentError.badRequest("fingerprint is 64 lowercase hex digits")
        }
        if let problem = JobsCommand.waitProblem(waitSeconds) { throw AgentError.badRequest(problem) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encodeIfPresent(parameters, forKey: .parameters)
        try container.encode(video, forKey: .video)
        try container.encode(maxCost, forKey: .maxCost)
        if waitSeconds != 0 { try container.encode(waitSeconds, forKey: .waitSeconds) }
    }
}

// MARK: Answers

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
