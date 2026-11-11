import Foundation

/// The resolution tiers the models render at, lowest first.
public enum Resolution: String, Codable, Sendable, CaseIterable {
    /// Gemini Omni Flash 1.2's lowest tier.
    case p360 = "360p"
    case p480 = "480p"
    case p720 = "720p"
    /// MiniMax H3 Max's higher tier.
    case p768 = "768p"
    case p1080 = "1080p"
    /// MiniMax H3's only tier, spelled as its schemas spell it.
    case k2 = "2K"
    /// Gemini Omni Flash 1.2's highest tier, spelled as its schema spells it.
    case k4 = "4k"

    /// What a model renders at unless `models.json` lists its own, and what Settings offers as a default.
    public static let standard: [Resolution] = [.p480, .p720, .p1080]

    /// The height of a 16:9 frame at this tier, in pixels; 2K is taken as 1440, the common 16:9 2K frame (MiniMax
    /// doesn't state its size), and 4K as 2160. `VideoModel.fitted` reads nearness by it.
    public var pixelHeight: Int {
        switch self {
        case .p360: 360
        case .p480: 480
        case .p720: 720
        case .p768: 768
        case .p1080: 1080
        case .k2: 1440
        case .k4: 2160
        }
    }

    /// The nearest of `standard`, for what takes only those (`reframe`'s output): 360p is 480p, 768p is 720p, 2K and
    /// 4K are 1080p.
    public var standardized: Resolution {
        switch self {
        case .p480, .p720, .p1080: self
        case .p360: .p480
        case .p768: .p720
        case .k2, .k4: .p1080
        }
    }
}
