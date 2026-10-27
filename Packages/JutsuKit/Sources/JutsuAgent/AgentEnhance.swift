import Foundation

// enhance: the Library's Enhance menu, on Higgsfield (paid, a job) or on this Mac (free, a run of its own).

/// The operations of the Library's Enhance menu.
public enum AgentEnhancement: String, Codable, Sendable, CaseIterable {
    case upscale, reframe
    case removeBackground = "remove_background"
    case dub
    case changeVoice = "change_voice"
    /// New frames between a video's own, on this Mac only.
    case smoothMotion = "smooth_motion"
}

/// Smooth Motion's modes, by the names agents use: 60 fps at the clip's own length and sound, or 2× and 4× slow motion
/// at the clip's own frame rate, without sound.
public enum AgentSmoothMotion: String, Codable, Sendable, CaseIterable {
    case fps60 = "60fps"
    case slow2x = "slow_2x"
    case slow4x = "slow_4x"

    static let names = allCases.map(\.rawValue).joined(separator: ", ")
}

/// One Enhance operation on a Library result, idempotent by its request ID. On Higgsfield it is queued as the Enhance
/// sheet queues it, a paid job on a video; on this Mac (`isOnDevice`: smooth_motion, or upscale with engine mac) it is
/// a free run that adds a new version of the item, a video or, for upscale, an image.
public struct EnhanceCommand: Codable, Equatable, Sendable, AgentFields {
    /// A voice ID's length, in UTF-8 bytes, which the schema's `maxLength` states for the ASCII IDs it takes.
    public static let maxVoiceLength = 128
    /// `engine` for a run on this Mac.
    public static let macEngine = "mac"
    /// The engines an upscale takes; topaz is refused later, with its own reason.
    public static let upscaleEngines = ["standard", "topaz", macEngine]

    public var requestID: String
    /// `AgentFingerprint` of the request's parameters and, for a paid one, `max_cost`.
    public var fingerprint: String
    /// The Library item: a video result, or an image for an upscale on this Mac.
    public var item: UUID
    public var operation: AgentEnhancement
    /// Upscale on Higgsfield: "1080p", "2k" or "4k"; 1080p when left out.
    public var target: String?
    /// Upscale on Higgsfield: 24, 30 or 60; 24 when left out.
    public var frameRate: Int?
    /// Upscale: "standard" on Higgsfield, "mac" on this Mac (4×); "topaz" is refused, as its price is known only after
    /// it runs. Smooth Motion: "mac" or left out.
    public var engine: String?
    /// Smooth Motion: one of `AgentSmoothMotion`.
    public var mode: String?
    /// Reframe: "9:16", "1:1" or "16:9".
    public var aspectRatio: String?
    /// Dub: an ISO 639-3 code such as "fra".
    public var language: String?
    /// Change Voice: a voice ID from `capabilities` (`voices`).
    public var voice: String?
    /// Needed on Higgsfield; a run on this Mac is free and goes without one (the helper drops one sent).
    public var maxCost: AgentAmount?

    public init(
        requestID: String, fingerprint: String, item: UUID, operation: AgentEnhancement, target: String? = nil,
        frameRate: Int? = nil, engine: String? = nil, mode: String? = nil, aspectRatio: String? = nil,
        language: String? = nil, voice: String? = nil, maxCost: AgentAmount?
    ) {
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.item = item
        self.operation = operation
        self.target = target
        self.frameRate = frameRate
        self.engine = engine
        self.mode = mode
        self.aspectRatio = aspectRatio
        self.language = language
        self.voice = voice
        self.maxCost = maxCost
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case fingerprint, item, operation, target, frameRate, engine, mode, aspectRatio, language, voice, maxCost
    }

    /// Runs on this Mac rather than on Higgsfield.
    public var isOnDevice: Bool { Self.isOnDevice(operation, engine: engine) }

    /// Whether `operation` with `engine` runs on this Mac: the helper asks before it reads `max_cost`.
    public static func isOnDevice(_ operation: AgentEnhancement, engine: String?) -> Bool {
        operation == .smoothMotion || (operation == .upscale && engine == macEngine)
    }

    public var problem: String? {
        guard AgentNames.isValidRequestID(requestID) else { return AgentNames.requestIDRule }
        guard AgentNames.isValidFingerprint(fingerprint) else { return "fingerprint is 64 lowercase hex digits" }
        if let extra = extraOption {
            let name = operation == .upscale && isOnDevice ? "upscale with engine mac" : operation.rawValue
            return "\(name) takes no \(extra)"
        }
        switch operation {
        case .reframe where aspectRatio == nil: return "reframe needs aspect_ratio: 9:16, 1:1 or 16:9"
        case .dub where language == nil: return "dub needs language, an ISO 639-3 code such as fra"
        case .changeVoice where voice == nil: return "change_voice needs voice, a voice ID from capabilities"
        case .smoothMotion where mode == nil: return "smooth_motion needs mode: \(AgentSmoothMotion.names)"
        case .smoothMotion where engine != nil && engine != Self.macEngine:
            return "smooth_motion runs on this Mac only: engine is mac or left out"
        default: break
        }
        if let mode, AgentSmoothMotion(rawValue: mode) == nil { return "mode is one of \(AgentSmoothMotion.names)" }
        for value in [target, engine, aspectRatio, language] {
            if let value, value.utf8.count > 16 {
                return "\(value.prefix(16)) is not an option of \(operation.rawValue)"
            }
        }
        if let voice, !(1...Self.maxVoiceLength).contains(voice.utf8.count) {
            return "voice is a voice ID from capabilities"
        }
        if let frameRate, ![24, 30, 60].contains(frameRate) { return "frame_rate is 24, 30 or 60" }
        if maxCost == nil, !isOnDevice {
            return "\(operation.rawValue) on Higgsfield needs max_cost; only smooth_motion and upscale with engine mac "
                + "run free on this Mac without one"
        }
        return nil
    }

    /// The first option sent that the operation doesn't take.
    private var extraOption: String? {
        let options: [(String, Bool)] = [
            ("target", target != nil), ("frame_rate", frameRate != nil), ("engine", engine != nil),
            ("mode", mode != nil), ("aspect_ratio", aspectRatio != nil), ("language", language != nil),
            ("voice", voice != nil),
        ]
        let allowed: Set<String> =
            switch operation {
            case .upscale: isOnDevice ? ["engine"] : ["target", "frame_rate", "engine"]
            case .smoothMotion: ["mode", "engine"]
            case .reframe: ["aspect_ratio"]
            case .removeBackground: []
            case .dub: ["language"]
            case .changeVoice: ["voice"]
            }
        return options.first { $0.1 && !allowed.contains($0.0) }?.0
    }
}
