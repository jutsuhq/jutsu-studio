import Foundation

public enum Mode: String, Codable, Sendable, CaseIterable {
    case motionTransfer
    case restyle
    case objectSwap
    /// Seedance changes an existing clip as the prompt says; the output follows the source's length and frame.
    case edit
    /// Seedance continues an existing clip past its last frame.
    case extend

    /// Genjutsu's limits, and Seedance's for Edit and Extend; `VideoModel.limits(for:)` gives each model's.
    public var limits: ModeLimits {
        switch self {
        case .motionTransfer, .objectSwap: ModeLimits(referenceImages: 1...8, requiresPreset: false)
        case .restyle: ModeLimits(referenceImages: 0...5, requiresPreset: true)
        case .edit, .extend: ModeLimits(referenceImages: 0...8, requiresPreset: false)
        }
    }

    /// Edit and Extend: operations on an existing clip, which need the source and a prompt (both REST schemas
    /// require `prompt` with at least one character).
    public var isVideoOperation: Bool { self == .edit || self == .extend }

    /// The model a job in this mode runs on when the picked one doesn't serve it: the first in the catalog that
    /// serves it (Genjutsu, and Seedance for Edit and Extend).
    public var defaultModel: VideoModel { VideoModel.allCases.first { $0.serves(self) } ?? .genjutsu }
}

public struct ModeLimits: Sendable, Hashable {
    public var referenceImages: ClosedRange<Int>
    public var requiresPreset: Bool
    /// Seconds of source one job takes; for Extend also the range of seconds it adds.
    public var duration: ClosedRange<TimeInterval>

    public init(
        referenceImages: ClosedRange<Int>, requiresPreset: Bool,
        duration: ClosedRange<TimeInterval> = Validation.durationRange
    ) {
        self.referenceImages = referenceImages
        self.requiresPreset = requiresPreset
        self.duration = duration
    }
}
