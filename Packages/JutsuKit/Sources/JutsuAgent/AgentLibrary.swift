import Foundation

// The commands of stage 3: create_image, library_search, library_mark and enhance (delivery_set and export are in
// AgentDelivery.swift), and what they answer. Each command checks its own fields as it decodes
// (`AgentFields.problem`), so the app refuses a malformed one with `bad_request` whatever sent it; the helper runs
// the same checks before it reads any file.

/// A command whose fields are checked as one, after they decode.
protocol AgentFields: Decodable {
    /// Why the fields can't be a command; nil when they can.
    var problem: String? { get }
}

extension AgentFields {
    /// Decodes the fields and refuses them with `bad_request` when they break a rule.
    static func checked(from decoder: any Decoder) throws -> Self {
        let fields = try Self(from: decoder)
        if let problem = fields.problem { throw AgentError.badRequest(problem) }
        return fields
    }
}

// MARK: create_image

/// The image an agent asks for, made as the Image side of Create would make it: a model of the connection, a frame
/// it takes, a count it makes and the images to edit, in order.
public struct AgentImageRequest: Codable, Equatable, Hashable, Sendable {
    /// More than any model makes, so the model's own counts refuse the rest with a reason.
    public static let maxCount = 16
    /// A bound of the protocol: the most a model may take where its catalog states no limit (`capabilities`
    /// imageModels `maxInputs` with `maxInputsNote`); a model's own limit refuses the rest with a reason. The same as
    /// JutsuCore's `ImageModel.inputBound`, which the helper can't link; a test keeps the two equal.
    public static let maxInputs = 14

    /// An image model ID from `capabilities` (`imageModels`); left out, the connection's first.
    public var model: String?
    public var prompt: String
    /// "1:1", "16:9"…; left out, 1:1 where the model takes it, else its first.
    public var aspectRatio: String?
    /// Images the request makes; 1 when left out.
    public var count: Int?
    /// For `create_image`: the images to edit, in order, paths in the app's inbox.
    public var inputs: [String]
    /// The account's reference elements by name (`elements`): their images go first, before `inputs`.
    public var elements: [String]
    /// What the Queue and the Library call the images, and their files' names, instead of the start of the prompt.
    public var title: String?

    public init(
        model: String? = nil, prompt: String, aspectRatio: String? = nil, count: Int? = nil, inputs: [String] = [],
        elements: [String] = [], title: String? = nil
    ) {
        self.model = model
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.count = count
        self.inputs = inputs
        self.elements = elements
        self.title = title
    }

    /// One input goes as `input` and several as `inputs`: a request of one input encodes as 0.2.0 encodes it, so its
    /// fingerprint matches the one 0.2.0 recorded.
    private enum CodingKeys: String, CodingKey {
        case model, prompt, aspectRatio, count, input, inputs, elements, title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        prompt = try container.decode(String.self, forKey: .prompt)
        aspectRatio = try container.decodeIfPresent(String.self, forKey: .aspectRatio)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        let input = try container.decodeIfPresent(String.self, forKey: .input)
        let inputs = try container.decodeIfPresent([String].self, forKey: .inputs)
        if input != nil, inputs != nil { throw AgentError.badRequest(Self.bothInputs) }
        self.inputs = inputs ?? input.map { [$0] } ?? []
        elements = try container.decodeIfPresent([String].self, forKey: .elements) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(count, forKey: .count)
        switch inputs.count {
        case 0: break
        case 1: try container.encode(inputs[0], forKey: .input)
        default: try container.encode(inputs, forKey: .inputs)
        }
        if !elements.isEmpty { try container.encode(elements, forKey: .elements) }
        try container.encodeIfPresent(title, forKey: .title)
    }

    public static let bothInputs = "send inputs, the images in order, or input, one image; not both"

    /// Shared by the helper and the app.
    public var problem: String? {
        if let model, !AgentNames.isValidImageModelID(model) { return "model is an image model ID from capabilities" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "prompt describes the image" }
        if prompt.unicodeScalars.count > AgentVideoRequest.maxPromptLength {
            return "prompt is at most \(AgentNames.spaced(AgentVideoRequest.maxPromptLength)) characters"
        }
        if let title, title.unicodeScalars.count > AgentVideoRequest.maxTitleLength {
            return "title is at most \(AgentNames.spaced(AgentVideoRequest.maxTitleLength)) characters"
        }
        if let aspectRatio, aspectRatio.utf8.count > 16 { return "aspect_ratio is a ratio such as 16:9" }
        if let count, !(1...Self.maxCount).contains(count) { return "count is 1 to \(Self.maxCount)" }
        if inputs.count > Self.maxInputs { return "inputs takes at most \(Self.maxInputs) images" }
        if let path = inputs.first(where: { !AgentVideoRequest.isValidPath($0) }) {
            return "inputs has a path that isn't one: \(path.prefix(80))"
        }
        if let problem = AgentElementNames.problem(elements) { return problem }
        return nil
    }
}

/// Makes images, idempotent by its request ID as `create_video` is.
public struct CreateImageCommand: Codable, Equatable, Sendable, AgentFields {
    public var requestID: String
    /// `AgentFingerprint` of the request as the agent sent it, with its input's path and size.
    public var fingerprint: String
    public var image: AgentImageRequest
    public var maxCost: AgentAmount

    public init(requestID: String, fingerprint: String, image: AgentImageRequest, maxCost: AgentAmount) {
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.image = image
        self.maxCost = maxCost
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case fingerprint, image, maxCost
    }

    public var problem: String? {
        guard AgentNames.isValidRequestID(requestID) else { return AgentNames.requestIDRule }
        guard AgentNames.isValidFingerprint(fingerprint) else { return "fingerprint is 64 lowercase hex digits" }
        return image.problem
    }
}

// MARK: library_search

/// What the Library holds, by the names agents use.
public enum AgentLibraryKind: String, Codable, Sendable, CaseIterable {
    case all, video, image
}

/// A culling verdict, as the Library's Keep and Reject set it.
public enum AgentVerdict: String, Codable, Sendable, CaseIterable {
    case unreviewed, kept, rejected
}

/// Finds results in the Library on this Mac, newest first, a page at a time. Rejected results stay out unless the
/// search asks for them (`verdict` rejected, or `includeRejected`).
public struct LibrarySearchCommand: Codable, Equatable, Sendable, AgentFields {
    public static let defaultLimit = 20
    public static let maxLimit = 50
    /// Prompts are cut to this many characters in the answer.
    public static let promptLength = 200
    /// In Unicode scalars.
    public static let maxQueryLength = 500
    /// In UTF-8 bytes, which the schema's `maxLength` states for the ASCII IDs and names it takes.
    public static let maxModelLength = 128

    /// Words that all appear in the prompt, the title or the model.
    public var query: String?
    public var kind: AgentLibraryKind?
    /// true: starred only; false: not starred only.
    // swiftlint:disable:next discouraged_optional_boolean
    public var starred: Bool?
    public var verdict: AgentVerdict?
    // swiftlint:disable:next discouraged_optional_boolean
    public var includeRejected: Bool?
    /// A video model ID or an image model's name.
    public var model: String?
    /// A video mode (`AgentVideoRequest.modes`); images have none, so they are left out.
    public var mode: String?
    /// Made at or after this time.
    public var from: Date?
    /// Made before this time.
    public var to: Date?
    public var limit: Int?
    /// `nextCursor` of the page before.
    public var cursor: String?
    /// Also lists the account's Higgsfield history the Library shows under From Higgsfield, results with no file on
    /// this Mac yet (`library_download` brings one here).
    // swiftlint:disable:next discouraged_optional_boolean
    public var includeHiggsfield: Bool?
    /// Loads the history from Higgsfield again first, as From Higgsfield's refresh does; free, never spends.
    // swiftlint:disable:next discouraged_optional_boolean
    public var refreshHiggsfield: Bool?

    public init(
        // swiftlint:disable:next discouraged_optional_boolean
        query: String? = nil, kind: AgentLibraryKind? = nil, starred: Bool? = nil, verdict: AgentVerdict? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        includeRejected: Bool? = nil, model: String? = nil, mode: String? = nil, from: Date? = nil, to: Date? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        limit: Int? = nil, cursor: String? = nil, includeHiggsfield: Bool? = nil, refreshHiggsfield: Bool? = nil
    ) {
        self.query = query
        self.kind = kind
        self.starred = starred
        self.verdict = verdict
        self.includeRejected = includeRejected
        self.model = model
        self.mode = mode
        self.from = from
        self.to = to
        self.limit = limit
        self.cursor = cursor
        self.includeHiggsfield = includeHiggsfield
        self.refreshHiggsfield = refreshHiggsfield
    }

    public var problem: String? {
        if refreshHiggsfield == true, includeHiggsfield != true {
            return "refresh_higgsfield loads the history include_higgsfield lists; send both"
        }
        if let query, query.unicodeScalars.count > Self.maxQueryLength {
            return "query is at most \(Self.maxQueryLength) characters"
        }
        if let model, model.utf8.count > Self.maxModelLength { return "model is a model ID or an image model's name" }
        if let mode, !AgentVideoRequest.modes.contains(mode) {
            return "mode is one of \(AgentVideoRequest.modes.joined(separator: ", "))"
        }
        if let from, let to, to <= from { return "to comes after from" }
        if let limit, !(1...Self.maxLimit).contains(limit) { return "limit is 1 to \(Self.maxLimit)" }
        if let cursor, !AgentNames.isValidCursor(cursor) { return "cursor is a nextCursor from an earlier answer" }
        return nil
    }
}

/// One result of the Library, as an agent sees it.
public struct AgentLibraryItem: Codable, Equatable, Sendable {
    /// The Library item's ID, which `library_mark`, `enhance`, `delivery_set` and `export` take.
    public var id: UUID
    public var kind: AgentLibraryKind
    /// The current version's file on this Mac; `nil` for a result only on Higgsfield.
    public var file: String?
    /// The video model's ID, or the image model's name.
    public var model: String?
    public var mode: String?
    /// "16:9", when known.
    public var aspectRatio: String?
    /// Seconds a video runs.
    public var duration: Double?
    public var price: AgentAmount?
    public var verdict: AgentVerdict
    public var starred: Bool
    public var createdAt: Date
    /// Cut to `LibrarySearchCommand.promptLength` characters.
    public var prompt: String
    public var promptTruncated: Bool
    /// The current version's ID; an edit brought back from another app is a newer version.
    public var versionID: UUID
    /// 1 for the original; the current version's place among the item's versions.
    public var version: Int
    public var versionCount: Int
    /// The video job that made it, when it was one (`jobs`, `show`); left out for a video only on Higgsfield.
    public var jobID: UUID?
    /// true for a result of the account's Higgsfield history with no file on this Mac yet; left out otherwise.
    // swiftlint:disable:next discouraged_optional_boolean
    public var onHiggsfield: Bool?

    public init(
        id: UUID, kind: AgentLibraryKind, file: String?, model: String?, mode: String?, aspectRatio: String?,
        duration: Double?, price: AgentAmount?, verdict: AgentVerdict, starred: Bool, createdAt: Date,
        prompt: String, promptTruncated: Bool, versionID: UUID, version: Int, versionCount: Int, jobID: UUID?,
        // swiftlint:disable:next discouraged_optional_boolean
        onHiggsfield: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.file = file
        self.model = model
        self.mode = mode
        self.aspectRatio = aspectRatio
        self.duration = duration
        self.price = price
        self.verdict = verdict
        self.starred = starred
        self.createdAt = createdAt
        self.prompt = prompt
        self.promptTruncated = promptTruncated
        self.versionID = versionID
        self.version = version
        self.versionCount = versionCount
        self.jobID = jobID
        self.onHiggsfield = onHiggsfield
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, file, model, mode, aspectRatio, duration, price, verdict, starred, createdAt, prompt
        case promptTruncated
        case versionID = "versionId"
        case version, versionCount
        case jobID = "jobId"
        case onHiggsfield
    }
}

public struct AgentLibraryPage: Codable, Equatable, Sendable {
    public var items: [AgentLibraryItem]
    /// Pass as `cursor` for the next page; nil on the last one.
    public var nextCursor: String?

    public init(items: [AgentLibraryItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

// MARK: library_mark

/// What `library_mark` sets on a culling verdict.
public enum AgentCulling: String, Codable, Sendable, CaseIterable {
    case keep, reject, clear
}

/// Sets the culling verdict and, apart from it, the star of Library items, as the Library's own buttons do. Doing it
/// again changes nothing; nothing is deleted or moved to the Trash.
public struct LibraryMarkCommand: Codable, Equatable, Sendable, AgentFields {
    public static let maxIDs = 100

    public var ids: [UUID]
    public var verdict: AgentCulling?
    // swiftlint:disable:next discouraged_optional_boolean
    public var star: Bool?

    // swiftlint:disable:next discouraged_optional_boolean
    public init(ids: [UUID], verdict: AgentCulling? = nil, star: Bool? = nil) {
        self.ids = ids
        self.verdict = verdict
        self.star = star
    }

    public var problem: String? {
        if let problem = AgentLibraryIDs.problem(ids, limit: Self.maxIDs, allowsRepeats: true) { return problem }
        guard verdict != nil || star != nil else { return "library_mark needs verdict, star or both" }
        return nil
    }
}

public struct AgentMarked: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var id: UUID
        public var verdict: AgentVerdict
        public var starred: Bool

        public init(id: UUID, verdict: AgentVerdict, starred: Bool) {
            self.id = id
            self.verdict = verdict
            self.starred = starred
        }
    }

    /// Each item as it is now.
    public var items: [Item]
    /// How many items this call changed; 0 when everything was already so.
    public var changed: Int

    public init(items: [Item], changed: Int) {
        self.items = items
        self.changed = changed
    }
}

// MARK: enhance

/// The operations of the Library's Enhance menu.
public enum AgentEnhancement: String, Codable, Sendable, CaseIterable {
    case upscale, reframe
    case removeBackground = "remove_background"
    case dub
    case changeVoice = "change_voice"
}

/// One Enhance operation on a video result, queued as the Enhance sheet queues it, idempotent by its request ID.
public struct EnhanceCommand: Codable, Equatable, Sendable, AgentFields {
    /// A voice ID's length, in UTF-8 bytes, which the schema's `maxLength` states for the ASCII IDs it takes.
    public static let maxVoiceLength = 128

    public var requestID: String
    /// `AgentFingerprint` of the request's parameters and `max_cost`.
    public var fingerprint: String
    /// The Library item, a video result.
    public var item: UUID
    public var operation: AgentEnhancement
    /// Upscale: "1080p", "2k" or "4k"; 1080p when left out.
    public var target: String?
    /// Upscale: 24, 30 or 60; 24 when left out.
    public var frameRate: Int?
    /// Upscale: "standard"; "topaz" is refused, as its price is known only after it runs.
    public var engine: String?
    /// Reframe: "9:16", "1:1" or "16:9".
    public var aspectRatio: String?
    /// Dub: an ISO 639-3 code such as "fra".
    public var language: String?
    /// Change Voice: a voice ID from `capabilities` (`voices`).
    public var voice: String?
    public var maxCost: AgentAmount

    public init(
        requestID: String, fingerprint: String, item: UUID, operation: AgentEnhancement, target: String? = nil,
        frameRate: Int? = nil, engine: String? = nil, aspectRatio: String? = nil, language: String? = nil,
        voice: String? = nil, maxCost: AgentAmount
    ) {
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.item = item
        self.operation = operation
        self.target = target
        self.frameRate = frameRate
        self.engine = engine
        self.aspectRatio = aspectRatio
        self.language = language
        self.voice = voice
        self.maxCost = maxCost
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case fingerprint, item, operation, target, frameRate, engine, aspectRatio, language, voice, maxCost
    }

    public var problem: String? {
        guard AgentNames.isValidRequestID(requestID) else { return AgentNames.requestIDRule }
        guard AgentNames.isValidFingerprint(fingerprint) else { return "fingerprint is 64 lowercase hex digits" }
        let options: [(String, Bool)] = [
            ("target", target != nil), ("frame_rate", frameRate != nil), ("engine", engine != nil),
            ("aspect_ratio", aspectRatio != nil), ("language", language != nil), ("voice", voice != nil),
        ]
        let allowed: Set<String> =
            switch operation {
            case .upscale: ["target", "frame_rate", "engine"]
            case .reframe: ["aspect_ratio"]
            case .removeBackground: []
            case .dub: ["language"]
            case .changeVoice: ["voice"]
            }
        if let extra = options.first(where: { $0.1 && !allowed.contains($0.0) }) {
            return "\(operation.rawValue) takes no \(extra.0)"
        }
        switch operation {
        case .reframe where aspectRatio == nil: return "reframe needs aspect_ratio: 9:16, 1:1 or 16:9"
        case .dub where language == nil: return "dub needs language, an ISO 639-3 code such as fra"
        case .changeVoice where voice == nil: return "change_voice needs voice, a voice ID from capabilities"
        default: break
        }
        for value in [target, engine, aspectRatio, language] {
            if let value, value.utf8.count > 16 {
                return "\(value.prefix(16)) is not an option of \(operation.rawValue)"
            }
        }
        if let voice, !(1...Self.maxVoiceLength).contains(voice.utf8.count) {
            return "voice is a voice ID from capabilities"
        }
        if let frameRate, ![24, 30, 60].contains(frameRate) { return "frame_rate is 24, 30 or 60" }
        return nil
    }
}
