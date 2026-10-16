import Foundation
import JutsuCore

extension KlingQuality {
    public var title: String {
        switch self {
        case .standard: String(localized: "Standard", bundle: .module)
        case .pro: String(localized: "Pro", bundle: .module)
        }
    }
}

extension Resolution {
    /// "720p"; on a model with a quality instead (Kling), the quality the resolution stands for, "Standard" or "Pro".
    public func title(on model: VideoModel) -> String {
        model.declares(.quality) ? KlingQuality(self).title : rawValue
    }
}

extension JobSpec {
    /// What the job was made at, as lists show it (`Resolution.title(on:)`).
    public var resolutionTitle: String { resolution.title(on: model) }
}
