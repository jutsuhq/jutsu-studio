import Foundation
import JutsuCore

/// A part of the trim strip that the arrow keys and VoiceOver can move.
public enum TrimPart: Sendable, Hashable, CaseIterable {
    case start, end, selection

    public var accessibilityLabel: String {
        switch self {
        case .start: String(localized: "Trim start", bundle: .module)
        case .end: String(localized: "Trim end", bundle: .module)
        case .selection: String(localized: "Trim range", bundle: .module)
        }
    }
}

/// The submit bar's main button, which ⌘↩ and the Generate menu item press: Generate, or Draft in a batch.
public struct PrimarySubmit: Sendable, Hashable {
    public var title: String
    public var isDraft: Bool
    /// `false` while a blocker stands or a submit is running.
    public var isEnabled: Bool
}

/// Keyboard and VoiceOver control of the Create form.
extension CreateForm {
    /// One arrow-key press or VoiceOver adjustment moves a trim handle by a tenth of a second, the precision
    /// the range is shown with.
    public static let trimStepsPerSecond: Double = 10

    /// Moves `part` by `steps` trim steps, negative is earlier, clamped as a drag is. The moved edge lands on
    /// the step grid, so stepping out and back returns to the same time instead of accumulating rounding error.
    public mutating func nudge(_ part: TrimPart, by steps: Int) {
        let target = { (time: TimeInterval) in
            (time * Self.trimStepsPerSecond + Double(steps)).rounded() / Self.trimStepsPerSecond
        }
        switch part {
        case .start: setStart(target(range.lowerBound))
        case .end: setEnd(target(range.upperBound))
        case .selection: moveRange(toStart: target(range.lowerBound))
        }
    }

    /// The frame a part shows in the preview: its own edge, or the start of the selection.
    public func time(of part: TrimPart) -> TimeInterval {
        part == .end ? range.upperBound : range.lowerBound
    }

    /// "00:06.0" for a handle, "00:06.0 – 00:18.5" for the selection.
    public func accessibilityValue(of part: TrimPart) -> String {
        switch part {
        case .start: CostText.timecode(range.lowerBound)
        case .end: CostText.timecode(range.upperBound)
        case .selection: rangeText
        }
    }

    /// What ⌘↩ submits now.
    public func primarySubmit(in context: CreateContext, isSubmitting: Bool = false) -> PrimarySubmit {
        let isDraft = runsAsDraft
        return PrimarySubmit(
            title: isDraft ? draftButtonTitle : generateButtonTitle, isDraft: isDraft,
            isEnabled: !isSubmitting && blocker(isDraft: isDraft, in: context) == nil)
    }
}
