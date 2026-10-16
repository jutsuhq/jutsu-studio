import Foundation

/// Decides which progress reports reach `JobEngine.events`. The re-encode fallback reports per sample,
/// hundreds of times a second, and every event is a whole `Job` for the UI.
/// Only progress is coalesced: every other change is published at once and resets the baseline.
struct ProgressCoalescer {
    /// Smallest change of the fraction worth publishing.
    var minStep = 0.01
    /// Seconds after which any change is published.
    var maxInterval: TimeInterval = 0.25

    private var published: [UUID: (progress: Double, at: Date)] = [:]

    /// Records an event the engine published for `id`.
    mutating func didPublish(_ id: UUID, progress: Double, at date: Date) {
        published[id] = (progress, date)
    }

    mutating func forget(_ id: UUID) {
        published[id] = nil
    }

    /// Whether progress reported for `id` should be published now. Start and end always are.
    func shouldPublish(_ id: UUID, progress: Double, at date: Date) -> Bool {
        if progress <= 0 || progress >= 1 { return true }
        guard let last = published[id] else { return true }
        if progress == last.progress { return false }
        return abs(progress - last.progress) >= minStep || date.timeIntervalSince(last.at) >= maxInterval
    }
}
