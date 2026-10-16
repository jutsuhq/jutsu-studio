import Foundation
import JutsuCore

/// When today's committed spend has to be read again: a job appears, changes state, gets its server price or
/// turns out to cost credits rather than the unlimited allowance, a reference image request starts or ends, or the
/// unit changes. Progress is left out, so a running job doesn't query the store on every tick.
public struct CommittedSpendKey: Sendable, Hashable {
    private struct Entry: Sendable, Hashable {
        let id: UUID
        let state: JobState
        let price: Cost
        let usesUnlimited: Bool
    }

    private let unit: Capabilities.CostUnit
    private let jobs: [Entry]
    private let images: [ImageCharge]

    public init(_ jobs: [Job], images: [ImageCharge] = [], unit: Capabilities.CostUnit) {
        self.unit = unit
        self.images = images
        self.jobs = jobs.map {
            Entry(id: $0.id, state: $0.state, price: $0.price, usesUnlimited: $0.spec.usesUnlimited)
        }
    }

    /// The next midnight after `now`, when the committed spend starts again from the new day's jobs.
    public static func nextDay(after now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }
}
