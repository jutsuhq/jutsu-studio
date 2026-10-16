import Foundation

/// Kling's quality mode, which it has instead of a resolution: Standard renders 720p, Pro 1080p. A job keeps it in
/// `JobSpec.resolution`, so any resolution below 1080p, such as a 480p draft made before the picker, is Standard.
public enum KlingQuality: String, Sendable, CaseIterable {
    case standard
    case pro

    public init(_ resolution: Resolution) {
        self = resolution == .p1080 ? .pro : .standard
    }

    /// The resolution a job at this quality is stored with.
    public var resolution: Resolution {
        switch self {
        case .standard: .p720
        case .pro: .p1080
        }
    }
}
