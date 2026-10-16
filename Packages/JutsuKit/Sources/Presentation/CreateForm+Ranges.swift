import Foundation
import JutsuCore

/// Several ranges of one source, each queued as its own job.
extension CreateForm {
    public var hasSeveralRanges: Bool { ranges.count > 1 }

    /// "00:06.0 – 00:18.5"; empty for an index outside the list.
    public func rangeText(at index: Int) -> String {
        guard ranges.indices.contains(index) else { return "" }
        let range = ranges[index]
        return "\(CostText.timecode(range.lowerBound)) – \(CostText.timecode(range.upperBound))"
    }

    /// Whole seconds billed over all ranges on `connection`; each job is rounded up on its own. Extend bills the part
    /// it adds, and with an API key its source range too (`Pricing.billedSeconds(for:on:)`).
    public func billedSeconds(on connection: ProviderKind?) -> Int {
        ranges.reduce(0) { total, range in
            let selected = range.upperBound - range.lowerBound
            let seconds: TimeInterval =
                switch (mode, connection) {
                case (.extend, .account): clipLength
                case (.extend, _): selected + clipLength
                default: selected
                }
            return total + Pricing.billedSeconds(seconds)
        }
    }

    /// Under the source name: "00:06.0 – 00:18.5 · 12.5 s", or "3 ranges · 30.0 s".
    public var sourceSummary: String {
        guard hasSeveralRanges else { return "\(rangeText) · \(CostText.seconds(selectedDuration))" }
        let total = ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        return String(localized: "\(ranges.count) ranges · \(CostText.seconds(total))", bundle: .module)
    }

    /// Parts of the source no range covers, for dimming on the timeline.
    public var uncoveredRanges: [ClosedRange<TimeInterval>] {
        gaps.filter { $0.upperBound > $0.lowerBound }
    }

    /// There is a gap of at least 4 s for another range.
    public var canAddRange: Bool { !isSourceRemote && nextRange != nil }

    /// Adds a range in the first gap of at least 4 s, as long as the edited one where it fits, and edits it.
    public mutating func addRange() {
        guard canAddRange, let next = nextRange else { return }
        let index = ranges.firstIndex { $0.lowerBound >= next.upperBound } ?? ranges.count
        ranges.insert(next, at: index)
        selectedRangeIndex = index
    }

    /// The last range can't be removed; removing the edited one edits the next, or the previous at the end.
    public mutating func removeRange(at index: Int) {
        guard hasSeveralRanges, ranges.indices.contains(index) else { return }
        ranges.remove(at: index)
        if index < selectedRangeIndex || selectedRangeIndex == ranges.count {
            selectedRangeIndex -= 1
        }
    }

    public mutating func selectRange(at index: Int) {
        guard ranges.indices.contains(index) else { return }
        selectedRangeIndex = index
    }

    /// Where the edited range may go: from the end of the previous range to the start of the next.
    var room: ClosedRange<TimeInterval> {
        let lower = ranges.indices.contains(selectedRangeIndex - 1) ? ranges[selectedRangeIndex - 1].upperBound : 0
        let upper =
            ranges.indices.contains(selectedRangeIndex + 1)
            ? ranges[selectedRangeIndex + 1].lowerBound : (source?.duration ?? 0)
        return lower...max(lower, upper)
    }

    /// Before, between and after the ranges, in order; empty without a source.
    private var gaps: [ClosedRange<TimeInterval>] {
        guard let total = source?.duration else { return [] }
        var gaps: [ClosedRange<TimeInterval>] = []
        var start: TimeInterval = 0
        for range in ranges {
            gaps.append(start...max(start, range.lowerBound))
            start = range.upperBound
        }
        gaps.append(start...max(start, total))
        return gaps
    }

    private var nextRange: ClosedRange<TimeInterval>? {
        let window = limits.duration
        let length = min(max(selectedDuration, window.lowerBound), window.upperBound)
        guard let gap = gaps.first(where: { $0.upperBound - $0.lowerBound >= window.lowerBound }) else { return nil }
        return gap.lowerBound...min(gap.upperBound, gap.lowerBound + length)
    }
}
