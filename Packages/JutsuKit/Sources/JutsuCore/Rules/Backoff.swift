import Foundation

/// Exponential backoff with jitter: the waits between polls of a running job, and between retries of a failed step.
/// Shared by the job engine and the work outside the queue (Generate…, character sheets), which poll on their own.
public struct Backoff: Sendable {
    private let initial: TimeInterval
    private let maximum: TimeInterval
    private let factor: Double
    private let jitter: Double
    private var current: TimeInterval

    /// - Parameter jitter: every wait is scaled by a random factor in `1 ± jitter`, 0–1.
    public init(initial: TimeInterval, maximum: TimeInterval, factor: Double, jitter: Double = 0) {
        self.initial = initial
        self.maximum = max(initial, maximum)
        self.factor = max(factor, 1)
        self.jitter = min(max(jitter, 0), 1)
        current = initial
    }

    /// Higgsfield's polling guide: start at 2 s, grow by 1.5× up to 10 s. Seconds.
    public static func polling(initial: TimeInterval = 2, maximum: TimeInterval = 10, jitter: Double = 0) -> Backoff {
        Backoff(initial: initial, maximum: maximum, factor: 1.5, jitter: jitter)
    }

    /// The next wait, in seconds.
    public mutating func next() -> TimeInterval {
        let base = current
        current = min(current * factor, maximum)
        return base * (1 + Double.random(in: -jitter...jitter))
    }

    /// Back to the first wait, as after a change of status.
    public mutating func reset() {
        current = initial
    }
}
