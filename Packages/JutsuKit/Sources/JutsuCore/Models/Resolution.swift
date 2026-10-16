import Foundation

/// The resolution tiers the models render at, lowest first.
public enum Resolution: String, Codable, Sendable, CaseIterable {
    case p480 = "480p"
    case p720 = "720p"
    /// MiniMax H3 Max's higher tier.
    case p768 = "768p"
    case p1080 = "1080p"
    /// MiniMax H3's only tier, spelled as its schemas spell it.
    case k2 = "2K"

    /// What a model renders at unless `models.json` lists its own, and what Settings offers as a default.
    public static let standard: [Resolution] = [.p480, .p720, .p1080]

    /// The height of a 16:9 frame at this tier, in pixels; 2K is taken as 1440, the common 16:9 2K frame (MiniMax
    /// doesn't state its size). `VideoModel.fitted` reads nearness by it.
    public var pixelHeight: Int {
        switch self {
        case .p480: 480
        case .p720: 720
        case .p768: 768
        case .p1080: 1080
        case .k2: 1440
        }
    }

    /// The nearest of `standard`, for what takes only those (`reframe`'s output): 768p is 720p, 2K is 1080p.
    public var standardized: Resolution {
        switch self {
        case .p480, .p720, .p1080: self
        case .p768: .p720
        case .k2: .p1080
        }
    }
}
