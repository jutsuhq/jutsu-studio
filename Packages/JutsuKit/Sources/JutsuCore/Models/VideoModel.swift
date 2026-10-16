import Foundation

/// The model a job runs on, by its ID in `models.json` (`VideoModelCatalog`), which describes everything else. Coded
/// as the bare ID, so jobs, templates and settings stored when this was an enum read the same; an ID the catalog
/// doesn't have fails to decode, as an unknown case did.
public struct VideoModel: RawRepresentable, Codable, Sendable, Hashable, CaseIterable {
    public let rawValue: String

    /// `nil` for an ID the catalog doesn't have.
    public init?(rawValue: String) {
        guard VideoModelCatalog.bundled[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(id: String) {
        rawValue = id
    }

    /// Higgsfield's own; serves Motion, Restyle and Swap, and is the model every connection offers.
    public static let genjutsu = VideoModel(id: "genjutsu")
    public static let seedance25 = VideoModel(id: "seedance25")
    public static let klingMotionControl = VideoModel(id: "klingMotionControl")

    /// In the catalog's order.
    public static var allCases: [VideoModel] {
        VideoModelCatalog.bundled.descriptors.map { VideoModel(id: $0.id) }
    }

    public var descriptor: VideoModelDescriptor {
        VideoModelCatalog.bundled[rawValue] ?? .unknown(rawValue)
    }

    public var title: String { localized("title", fallback: descriptor.title) }

    /// The picker's short name, shared by a family's models.
    public var family: String { localized("family", fallback: descriptor.family) }

    /// One line under the picker.
    public var detail: String { localized("detail", fallback: descriptor.detail) }

    /// The modes it serves, in the catalog's order.
    public var modes: [Mode] { descriptor.modes }

    /// The resolutions it renders at, lowest first.
    public var resolutions: [Resolution] { descriptor.resolutions }

    /// `resolution` when the model renders at it, else the one it does nearest in frame height
    /// (`Resolution.pixelHeight`), the higher on a tie: a form or a template kept at 480p asks Wan 2.7, which starts
    /// at 720p, for 720p; MiniMax H3 Max's 768p asks the others for 720p, and MiniMax H3's 2K for 1080p.
    public func fitted(_ resolution: Resolution) -> Resolution {
        guard !resolutions.contains(resolution) else { return resolution }
        let distance = { (candidate: Resolution) in abs(candidate.pixelHeight - resolution.pixelHeight) }
        return resolutions.reversed().min { distance($0) < distance($1) } ?? resolution
    }

    public func serves(_ mode: Mode) -> Bool { descriptor.modes.contains(mode) }

    /// Whether the REST API runs it, with an API key; a model without endpoints runs on the account only (MiniMax H3
    /// Max, which the public docs don't list).
    public var runsWithAPIKey: Bool { !descriptor.endpoints.isEmpty }

    /// Whether Create shows `control` for this model.
    public func declares(_ control: VideoModelDescriptor.Control) -> Bool { descriptor.controls.contains(control) }

    /// Makes a clip from the prompt and images alone (`clipWithoutSource`).
    public var makesClipsWithoutSource: Bool { declares(.clipWithoutSource) }

    /// A model without a draft has a cheapest quality instead (Kling's Standard, whose 480p costs as much as 720p).
    public var offersDraft: Bool { declares(.draft) }

    /// The REST endpoint a job on this model runs on with an API key; also its key in `pricing.json`. The first of
    /// the catalog's `endpoints` keys that applies: the mode (Genjutsu's modes, Seedance's Edit and Extend), `frames`
    /// for a start and end frame (`usesFrames`), the quality (`standard` or `pro`) for a model with one, `reference`
    /// with a source or images and `text` without, then `default`. Empty when none is listed, which `Pricing` refuses
    /// at load.
    public func endpointID(for mode: Mode, resolution: Resolution, hasMedia: Bool, usesFrames: Bool = false) -> String {
        let endpoints = descriptor.endpoints
        let keys = [
            mode.rawValue, usesFrames ? "frames" : nil, declares(.quality) ? KlingQuality(resolution).rawValue : nil,
            hasMedia ? "reference" : "text", "default",
        ]
        return keys.lazy.compactMap { $0.flatMap { endpoints[$0] } }.first ?? ""
    }

    /// What one job on this model takes in `mode`: the mode's limits with the catalog's over them. Seedance's 4–30 s
    /// is confirmed by `get_cost`, and Kling's one image by the server refusing more ("exactly one image_references
    /// entry is required"); a limit with no quote, schema or refusal behind it is Genjutsu's. Without a source
    /// (`hasSource`) the prompt may stand alone, so no image is required. Edit takes up to 30 s of source and makes as
    /// much; Extend takes up to 30 s of source and adds 4–30 s (`duration` 4–30 in the `video-extend` schema).
    /// `constraints` replaces these with what the server says, bound by bound, where it says something.
    public func limits(
        for mode: Mode, hasSource: Bool = true, constraints: ModelConstraintTable = .builtIn
    ) -> ModeLimits {
        var limits = mode.limits
        if let duration = descriptor.duration { limits.duration = duration }
        if let images = descriptor.referenceImages { limits.referenceImages = images }
        if let server = constraints[self, mode] { limits = server.applied(to: limits) }
        if !hasSource { limits.referenceImages = 0...limits.referenceImages.upperBound }
        return limits
    }

    /// The account's `generate_video` model ID for a job in `mode`; `nil` where the account doesn't run it.
    public func accountModelID(for mode: Mode) -> String? { descriptor.accountModels[mode] }

    /// The `<id>.<field>` key in `Models.xcstrings`, with the catalog's English as the fallback.
    private func localized(_ field: String, fallback: String) -> String {
        guard !fallback.isEmpty else { return "" }
        return JutsuCoreResources.bundle.localizedString(
            forKey: "\(rawValue).\(field)", value: fallback, table: "Models")
    }
}
