import Foundation
import JutsuCore

/// Why an agent's `enhance` isn't queued.
public struct AgentEnhanceRefusal: Error, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Fields the operation doesn't take.
        case invalid
        /// Topaz: Higgsfield prices it only once it has run, so no guard could check it first.
        case pricedAfterRun
        /// The result or the connection can't run it now.
        case unavailable
    }

    public var kind: Kind
    public var message: String
}

/// An agent's `enhance` fields as the Enhance sheet's options, and whether the sheet would queue them for this
/// result. The job is then queued like the sheet's (`Job.operationSpec`), with the agent's origin, so the spending
/// guard checks it before its submit.
public struct AgentEnhanceOrder: Sendable, Hashable {
    public typealias Refusal = AgentEnhanceRefusal

    public var kind: PostAction.Kind
    public var target: String?
    public var frameRate: Int?
    public var engine: String?
    public var aspectRatio: String?
    public var language: String?
    public var voice: String?

    public init(
        kind: PostAction.Kind, target: String? = nil, frameRate: Int? = nil, engine: String? = nil,
        aspectRatio: String? = nil, language: String? = nil, voice: String? = nil
    ) {
        self.kind = kind
        self.target = target
        self.frameRate = frameRate
        self.engine = engine
        self.aspectRatio = aspectRatio
        self.language = language
        self.voice = voice
    }

    /// The operation the fields name, with the sheet's defaults for what is left out.
    /// - Parameter voices: the account's voices, for Change Voice; `nil` when they can't be read.
    public func action(voices: [VoiceChoice]?) -> Result<PostAction, Refusal> {
        switch kind {
        case .upscale:
            let engine = engine.map { UpscaleEngine(rawValue: $0) } ?? .standard
            guard let engine else { return .failure(Self.invalid("engine is standard")) }
            if engine == .topaz {
                return .failure(
                    Refusal(
                        kind: .pricedAfterRun,
                        message: "Topaz is priced only after it runs, so an agent can't queue it within max_cost."))
            }
            guard let target = target.map({ UpscaleTarget(rawValue: $0) }) ?? .p1080, engine.targets.contains(target)
            else { return .failure(Self.invalid("target is one of 1080p, 2k, 4k")) }
            let rate = frameRate.map { UpscaleFrameRate(rawValue: $0) } ?? .fps24
            guard let rate, UpscaleFrameRate.offered.contains(rate) else {
                return .failure(Self.invalid("frame_rate is 24, 30 or 60"))
            }
            return .success(.upscale(UpscaleOptions(target: target, frameRate: rate, engine: engine)))
        case .reframe:
            guard let aspect = aspectRatio.flatMap(ReframeAspect.init(rawValue:)) else {
                return .failure(Self.invalid("aspect_ratio is one of 9:16, 1:1, 16:9"))
            }
            return .success(.reframe(aspect))
        case .removeBackground:
            return .success(.removeBackground)
        case .dub:
            guard let language = language.flatMap(DubLanguage.init(rawValue:)) else {
                let codes = DubLanguage.allCases.map(\.rawValue).joined(separator: ", ")
                return .failure(Self.invalid("language is one of \(codes)"))
            }
            return .success(.dub(language))
        case .changeVoice:
            guard let voices else {
                return .failure(
                    Refusal(kind: .unavailable, message: "The account's voices can't be read right now."))
            }
            guard let choice = voices.first(where: { $0.id == voice }) else {
                return .failure(Self.invalid("voice is a voice ID from capabilities with voices true"))
            }
            return .success(.changeVoice(choice))
        }
    }

    /// Why the sheet wouldn't queue `action` on `item`; `nil` when it would.
    /// - Parameter duration: the result's length, as probed or stored.
    public static func refusal(
        _ action: PostAction, on item: LibraryItemModel, availability: EnhanceAvailability, duration: TimeInterval
    ) -> Refusal? {
        switch availability {
        case .hidden:
            return Refusal(
                kind: .unavailable,
                message: "Enhance runs on a downloaded video result with a Higgsfield account connected.")
        case .disabled(let reason):
            return Refusal(kind: .unavailable, message: reason)
        case .available:
            break
        }
        if case .reframe = action, duration > ReframeAspect.maxSourceLength {
            return Refusal(kind: .unavailable, message: "Reframe takes results up to a minute long.")
        }
        return nil
    }

    private static func invalid(_ message: String) -> Refusal { Refusal(kind: .invalid, message: message) }
}
