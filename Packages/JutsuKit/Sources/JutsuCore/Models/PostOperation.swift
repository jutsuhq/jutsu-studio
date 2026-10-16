import Foundation

/// A job that works on an existing result instead of generating one (Upscale, Reframe, Remove Background, Dub,
/// Change Voice). The job's
/// `source` is the result's file and `Job.parentID` the result it was made from.
public struct PostOperation: Codable, Sendable, Hashable {
    public var action: PostAction
    /// The result's job ID on the account that made it. The operation names the result by it instead of uploading
    /// the file; `nil` uploads `JobSpec.source`, as does a server that refuses the ID.
    public var sourceJobID: String?

    public init(action: PostAction, sourceJobID: String? = nil) {
        self.action = action
        self.sourceJobID = sourceJobID
    }
}

public enum PostAction: Codable, Sendable, Hashable {
    case upscale(UpscaleOptions)
    /// Keeps the subject on a black background. Live on 2026-10-15 the result was an H.264 MP4 without alpha or
    /// audio, the source's size and length, so nothing in it is transparent.
    case removeBackground
    /// A new canvas of another aspect ratio around the whole result, its new edges filled in.
    case reframe(ReframeAspect)
    /// The speech translated into another language and lip-synced.
    case dub(DubLanguage)
    /// The speaker's voice replaced by another one, keeping the timing.
    case changeVoice(VoiceChoice)

    // Stored jobs name the case, so a case is never renamed; a new one leaves old jobs decodable.

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case upscale
        case reframe
        case removeBackground
        case dub
        case changeVoice
    }

    public var kind: Kind {
        switch self {
        case .upscale: .upscale
        case .removeBackground: .removeBackground
        case .reframe: .reframe
        case .dub: .dub
        case .changeVoice: .changeVoice
        }
    }
}

extension PostAction {
    /// Whether Higgsfield prices the operation only once it has run: a Topaz upscale has no cost preflight, so its
    /// charge is read from the account's credit history when it finishes (`GenerationProvider.charge(of:)`).
    public var isPricedAfterRun: Bool {
        if case .upscale(let options) = self { return options.engine == .topaz }
        return false
    }

    /// Whether the result gets the source's sound back after download, as a generation does (`AudioPlan`): Remove
    /// Background's result has no audio track (live, 2026-10-15). Dub and Change Voice make their own sound, and
    /// what Upscale and Reframe return hasn't been seen, so those keep the result as it came.
    public var restoresSourceSound: Bool { self == .removeBackground }
}

public struct UpscaleOptions: Codable, Sendable, Hashable {
    public var target: UpscaleTarget
    public var frameRate: UpscaleFrameRate
    public var engine: UpscaleEngine

    public init(target: UpscaleTarget = .p1080, frameRate: UpscaleFrameRate = .fps24, engine: UpscaleEngine = .standard)
    {
        self.target = target
        self.frameRate = frameRate
        self.engine = engine
    }
}

public enum UpscaleTarget: String, Codable, Sendable, CaseIterable {
    case p1080 = "1080p"
    case k2 = "2k"
    case k4 = "4k"
}

public enum UpscaleFrameRate: Int, Codable, Sendable, CaseIterable {
    /// Kept for jobs stored before the catalog was known: nothing is sent, so the upscaler uses its default, 24 fps.
    /// Not offered (`offered`).
    case keep = 0
    case fps24 = 24
    case fps30 = 30
    /// Costs twice as much as 30 fps or less.
    case fps60 = 60

    public static let offered: [UpscaleFrameRate] = [.fps24, .fps30, .fps60]
}

public enum UpscaleEngine: String, Codable, Sendable, CaseIterable {
    /// Higgsfield's own upscaler (provider `bytedance`), which needs the source's size and takes a frame rate.
    case standard
    /// Topaz Video: 1080p or 4K, at the source's frame rate.
    case topaz

    /// The targets the engine offers.
    public var targets: [UpscaleTarget] {
        switch self {
        case .standard: UpscaleTarget.allCases
        case .topaz: [.p1080, .k4]
        }
    }

    /// Whether the engine takes a frame rate.
    public var takesFrameRate: Bool { self == .standard }
}

/// The canvases Reframe offers. The tool also takes 4:3, 3:4 and 21:9, but not 4:5.
public enum ReframeAspect: String, Codable, Sendable, CaseIterable {
    case portrait = "9:16"
    case square = "1:1"
    case landscape = "16:9"

    public var widthOverHeight: Double {
        switch self {
        case .portrait: 9.0 / 16
        case .square: 1
        case .landscape: 16.0 / 9
        }
    }

    /// The longest result Reframe takes, in seconds.
    public static let maxSourceLength: TimeInterval = 60
}

/// The languages a result can be dubbed into, by the ISO 639-3 code the dubbing tool takes.
public enum DubLanguage: String, Codable, Sendable, CaseIterable {
    case english = "eng"
    case chinese = "cmn"
    case french = "fra"
    case hindi = "hin"
    case italian = "ita"
    case japanese = "jpn"
    case korean = "kor"
    case portuguese = "por"
    case russian = "rus"
    case turkish = "tur"
    case spanish = "spa"
    case german = "deu"
    case arabic = "ara"
    case polish = "pol"
    case indonesian = "ind"
    case filipino = "fil"
    case swedish = "swe"
    case finnish = "fin"
}

/// The voice a result's speaker is changed to, as the provider's voice list names it.
public struct VoiceChoice: Codable, Sendable, Hashable {
    public var id: String
    /// The provider's kind of voice ("preset", "element"), sent back as it came.
    public var type: String
    /// What the voice list calls it, for titles.
    public var name: String

    public init(id: String, type: String, name: String) {
        self.id = id
        self.type = type
        self.name = name
    }
}

extension Cost {
    /// The price of a job no quote or public rate exists for: an operation without a cost preflight (only Reframe
    /// has one), or an account model whose credits per second aren't known before upload. Charged on completion.
    /// Never shown as a number (`Job.priceIsUnknown`).
    public static let unknownCredits = Cost.credits(0, isEstimate: true)
    /// The list price of a REST tariff no public page states (`Pricing.unpriced`), until the server quotes the
    /// uploaded inputs.
    public static let unknownUSD = Cost.usd(0, isEstimate: true)

    /// `unknownCredits` or `unknownUSD`.
    public var isUnknownPrice: Bool { self == .unknownCredits || self == .unknownUSD }
}

extension Job {
    /// A job whose price wasn't known when it was queued and that no answer has priced since.
    public var priceIsUnknown: Bool { price.isUnknownPrice }
}
