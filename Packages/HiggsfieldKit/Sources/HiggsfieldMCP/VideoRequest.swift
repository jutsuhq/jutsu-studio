import Foundation

/// The `params` of one `generate_video` call. `use_unlim` is always sent, `false` unless `usesUnlimited`: left
/// out, the server submits nothing for a model the allowance covers and answers with `unlim_choice`, a question for
/// the user.
public struct VideoRequest: Sendable, Hashable {
    /// A `generate_video` model, by the ID `models_explore` lists it under. Any ID is one: which models the app
    /// runs is data (JutsuKit's `models.json`), so a new account model needs no code here. The constants are the
    /// ones this package names itself (Genjutsu's galleries) or its tests use.
    public struct Model: RawRepresentable, Sendable, Hashable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Genjutsu Motion Transfer.
        public static let motionControl = Model(rawValue: "hf_mult_motion_control")
        /// Genjutsu Object Swap.
        public static let replaceObject = Model(rawValue: "hf_mult_replace_object")
        public static let seedance25 = Model(rawValue: "seedance_2_5")
        public static let klingMotionControl = Model(rawValue: "kling3_0_motion_control")
    }

    /// An uploaded file, by its `media_id`.
    public struct Media: Sendable, Hashable {
        public var role: MediaRole
        public var id: String

        public init(role: MediaRole, id: String) {
            self.role = role
            self.id = id
        }
    }

    /// `mode` values, as `models_explore get` names them (catalog snapshot of 2026-10-15): Seedance's and Cinema
    /// Studio's modes for a prompt alone and for reference media (start and end frames among them), and Kling's two
    /// quality modes (Kling O3 Edit's `4k` isn't sent).
    public static let textToVideo = "t2v"
    public static let omniReference = "omni_reference"
    /// Seedance's Edit: one reference video changed by the prompt; `duration` and `aspect_ratio` are ignored and
    /// the job is billed by the video's length.
    public static let seedanceEdit = "video_edit"
    /// Seedance's Extend: `duration` is the added part; `aspect_ratio` is ignored. Needs `extensionMode`.
    public static let seedanceExtend = "video_extension"
    /// Extend's `extension_mode`, required by `video_extension` and refused by the other modes: the new part
    /// follows the clip (`backward` would come before it).
    public static let extendForward = "forward"
    public static let klingStandard = "std"
    public static let klingPro = "pro"
    /// Kling's `background_source`: the output keeps the reference video's background, not the image's.
    public static let backgroundFromVideo = "input_video"

    public var model: Model
    /// Left out when empty, as for Seedance's `t2v`.
    public var media: [Media]
    /// Left out when empty.
    public var prompt: String
    /// "480p", "720p" or "1080p", from the model's `resolution` options; Kling takes `mode` instead.
    public var resolution: String?
    public var mode: String?
    /// Seconds: Seedance and Cinema Studio take 4–30, Wan 3.0 2–30; Kling 3.0 requires it, Kling O3 Edit takes
    /// none.
    public var duration: Double?
    /// Seedance, Wan 3.0 and Cinema Studio: whether the model generates a soundtrack.
    // swiftlint:disable:next discouraged_optional_boolean
    public var generateAudio: Bool?
    /// Kling only: which input the background comes from; left out for the server's default, the image.
    public var backgroundSource: String?
    /// Seedance without a reference video: "16:9", "9:16", "auto"…; a reference video sets the frame otherwise.
    public var aspectRatio: String?
    /// Seedance: "standard" (the server's default) or "high".
    public var bitrateMode: String?
    /// Seedance's Extend only (`extension_mode`): `extendForward`.
    public var extensionMode: String?
    /// `use_unlim`: pay from the plan's unlimited allowance instead of credits. Set only for a model that
    /// `UnlimitedAllowance.covers`.
    public var usesUnlimited = false
    /// `count`: how many variants of the same prompt, inputs and settings the request makes, 1–4, each its own job.
    /// Sent only above 1, and never with `use_unlim`: the server caps an unlimited request to one generation.
    public var count = 1
    /// Seedance 2.5's `draft`: a 480p draft that `draftJobID` can finalize at 1080p within seven days. Sent only when
    /// set. Live on 2026-10-15 it was priced and charged as the same request without it.
    public var draft = false
    /// Seedance 2.5's `draft_job_id`: the completed draft job to finalize at 1080p. A finalize sends only `model`,
    /// this, `resolution` and `use_unlim` (`finalize(draftJobID:)`): with `mode`, `prompt`, `duration` and
    /// `aspect_ratio` beside it, the quote of 2026-10-15 was a fresh 1080p render's.
    public var draftJobID: String?

    public init(
        model: Model, media: [Media], prompt: String = "", resolution: String? = nil, mode: String? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        duration: Double? = nil, generateAudio: Bool? = nil
    ) {
        self.model = model
        self.media = media
        self.prompt = prompt
        self.resolution = resolution
        self.mode = mode
        self.duration = duration
        self.generateAudio = generateAudio
    }

    /// The finalize of a completed Seedance 2.5 draft at 1080p: `{model, draft_job_id, resolution: "1080p",
    /// use_unlim: false}` and nothing else.
    public static func finalize(draftJobID: String) -> VideoRequest {
        var request = VideoRequest(model: .seedance25, media: [], resolution: finalizeResolution)
        request.draftJobID = draftJobID
        return request
    }

    /// What a draft is finalized at; `draft_job_id` takes no other.
    public static let finalizeResolution = "1080p"

    /// With `getCost`, the server quotes the request instead of submitting it. `declinedPresetID` turns down a
    /// preset the server suggested for this prompt, so the prompt is used as written.
    func arguments(getCost: Bool = false, declinedPresetID: String? = nil) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            ToolKey.model: .string(model.rawValue),
            ToolKey.useUnlim: .bool(usesUnlimited),
        ]
        if !media.isEmpty {
            params[ToolKey.medias] = .array(
                media.map { [ToolKey.role: .string($0.role.rawValue), ToolKey.value: .string($0.id)] })
        }
        let strings: [(key: String, value: String?)] = [
            (ToolKey.resolution, resolution), (ToolKey.mode, mode), (ToolKey.backgroundSource, backgroundSource),
            (ToolKey.aspectRatio, aspectRatio), (ToolKey.bitrateMode, bitrateMode),
            (ToolKey.extensionMode, extensionMode), (ToolKey.draftJobID, draftJobID),
        ]
        for (key, value) in strings {
            if let value { params[key] = .string(value) }
        }
        if let duration { params[ToolKey.duration] = .number(duration) }
        if draft { params[ToolKey.draft] = true }
        if count > 1, !usesUnlimited { params[ToolKey.count] = .number(Double(count)) }
        if let generateAudio { params[ToolKey.generateAudio] = .bool(generateAudio) }
        if !prompt.isEmpty { params[ToolKey.prompt] = .string(prompt) }
        if getCost { params[ToolKey.getCost] = true }
        if let declinedPresetID { params[ToolKey.declinedPresetID] = .string(declinedPresetID) }
        return [ToolKey.params: .object(params)]
    }
}

/// What an uploaded file is to the generation. The server renames `video` and `image` to these for the
/// `VideoRequest` models.
public enum MediaRole: String, Sendable {
    case video = "video_references"
    case image = "image_references"
    /// Seedance's start and end frames, sent with `mode` `omni_reference`: `seedance_2_5`'s `medias` roles, and the
    /// mode the server's Seedance 2.5 tools put these roles under (catalog snapshot of 2026-10-15).
    case startFrame = "start_image"
    case endFrame = "end_image"
}

/// A submitted generation.
public struct Generation: Sendable, Hashable {
    /// What `status(of:)` takes.
    public var id: String
    /// The server's trace ID, for support requests.
    public var requestID: String?
    /// Credits the answer says the job costs (`cost.credits_exact` or `cost.credits`, as in a quote); `nil` when
    /// it names none, which per `generate_video`'s `outputSchema` is always: `cost` comes only with `get_cost`.
    public var credits: Double?
    /// The other jobs the same request started, one per further variant (`VideoRequest.count`), in the answer's
    /// order. Each is polled like `id`; `credits` is the whole request's and isn't repeated for them.
    public var variantIDs: [String]

    init(id: String, requestID: String?, credits: Double? = nil, variantIDs: [String] = []) {
        self.id = id
        self.requestID = requestID
        self.credits = credits
        self.variantIDs = variantIDs
    }
}

/// An uploaded and confirmed file.
public struct UploadedMedia: Sendable, Hashable {
    /// What `VideoRequest.Media` takes.
    public var id: String
    public var url: URL

    public init(id: String, url: URL) {
        self.id = id
        self.url = url
    }
}

public struct AccountBalance: Sendable, Hashable {
    public var credits: Double
    /// `subscription_plan_type`, e.g. "creator_plus".
    public var plan: String?
}
