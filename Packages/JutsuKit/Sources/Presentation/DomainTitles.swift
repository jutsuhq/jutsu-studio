import Foundation
import JutsuCore

// Names of JutsuCore values as the UI shows them. JutsuCore has no string catalog, so their text lives here.

extension MotionShelf {
    public var title: String {
        switch self {
        case .featured: "Higgsfield"
        case .trending: String(localized: "Trending", bundle: .module)
        case .new: String(localized: "New", bundle: .module)
        case .uploads: String(localized: "Your Uploads", bundle: .module)
        }
    }
}

extension Rejection {
    /// "Rejected: …", for the queue row and notifications.
    public var title: String {
        switch self {
        case .explicitContent: String(localized: "Rejected as explicit content", bundle: .module)
        case .protectedContent:
            String(localized: "Rejected: a recognizable person or protected content", bundle: .module)
        }
    }
}

extension AspectRatio {
    public var title: String { self == .auto ? String(localized: "Auto", bundle: .module) : rawValue }
}

extension OutputNamePattern.Token {
    /// What the token stands for, with an example, for the pattern's help in Settings.
    public var meaning: String {
        switch self {
        case .date: String(localized: "date the job was queued, 2026-03-07", bundle: .module)
        case .time: String(localized: "time it was queued, 14-05-09", bundle: .module)
        case .mode: String(localized: "mode, restyle", bundle: .module)
        case .preset: String(localized: "preset name, empty without a preset", bundle: .module)
        case .res: String(localized: "resolution, 720p", bundle: .module)
        case .draft: String(localized: "\"draft\" for drafts, otherwise empty", bundle: .module)
        case .id: String(localized: "first 8 characters of the job ID", bundle: .module)
        }
    }
}
