import Foundation

/// The divider of a compare surface: the first video shows left of it, the second right of it.
public struct CompareDivider: Sendable, Hashable {
    /// One arrow-key press moves the divider by this fraction of the width.
    public static let keyboardStep = 0.05

    /// Fraction of the player's width, 0...1.
    public private(set) var position: Double

    public init(position: Double = 0.5) {
        self.position = Self.clamped(position)
    }

    /// Follows a drag at `x` points across a player `width` points wide.
    public mutating func drag(to x: Double, width: Double) {
        guard width > 0 else { return }
        position = Self.clamped(x / width)
    }

    /// Moves by `steps` keyboard steps; negative is left.
    public mutating func nudge(by steps: Int) {
        position = Self.clamped(position + Double(steps) * Self.keyboardStep)
    }

    /// "50%", for the accessibility value.
    public var percentText: String {
        CostText.percent(fraction: position)
    }

    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}

/// Keeps a follower on the lead result's clock. A result was rendered from its source's `range`, so result
/// time `t` is source time `range.lowerBound + t`; without a range, e.g. another result, it is `t`.
public struct CompareClock: Sendable, Hashable {
    /// Drift the eye doesn't catch side by side; correcting below it would make the source stutter.
    public static let driftTolerance: TimeInterval = 0.1

    public var sourceRange: ClosedRange<TimeInterval>?

    public init(sourceRange: ClosedRange<TimeInterval>?) {
        self.sourceRange = sourceRange
    }

    /// Where the source should be when the result is at `resultTime`; holds at the range's end.
    public func sourceTime(atResult resultTime: TimeInterval) -> TimeInterval {
        let start = sourceRange?.lowerBound ?? 0
        let time = start + max(0, resultTime.isFinite ? resultTime : 0)
        guard let end = sourceRange?.upperBound else { return time }
        return min(time, end)
    }

    /// The time to seek the source to, or `nil` while it is close enough or a time isn't known yet.
    public func correction(resultTime: TimeInterval, sourceTime: TimeInterval) -> TimeInterval? {
        guard resultTime.isFinite, sourceTime.isFinite else { return nil }
        let target = self.sourceTime(atResult: resultTime)
        return abs(sourceTime - target) > Self.driftTolerance ? target : nil
    }
}
