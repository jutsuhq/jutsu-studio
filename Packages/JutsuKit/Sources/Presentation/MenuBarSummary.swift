import Foundation
import JutsuCore

/// What the menu bar panel shows: the active jobs with progress and what the connection has spent or has left.
public struct MenuBarSummary: Sendable, Hashable {
    /// More rows than this make the panel taller than a laptop screen.
    public static let rowLimit = 6

    /// "No jobs in the queue", "3 jobs in the queue · 1 paused".
    public var headline: String
    public var rows: [JobRowModel]
    /// "and 2 more", when the queue has more jobs than rows.
    public var overflow: String?
    /// "Committed today: $12.40" for an API key, "Credits left: 1,250" for an account; `nil` when unknown.
    public var balance: String?

    /// - Parameters:
    ///   - jobs: every job the app knows, finished ones included for today's spend; the rows keep their order.
    ///   - images: the reference image requests, which count toward today's spend too.
    ///   - times: for the time estimate of generating jobs.
    public init(
        jobs: [Job], images: [ImageCharge] = [], connection: ConnectionState, now: Date,
        times: GenerationTimes = GenerationTimes(), calendar: Calendar = .current, locale: Locale = .current
    ) {
        let active = jobs.filter(\.state.isActive)
        let paused = active.count(where: \.state.isPaused)
        headline = Self.headline(active: active.count, paused: paused)
        rows = active.prefix(Self.rowLimit).map { JobRowModel($0, now: now, typical: times.estimate(for: $0.spec)) }
        overflow =
            active.count > Self.rowLimit
            ? String(localized: "and \(active.count - Self.rowLimit) more", bundle: .module) : nil
        switch connection {
        case .none:
            balance = nil
        case .apiKey:
            let committed = DailySpend.committed(jobs, images: images, on: now, calendar: calendar)
            balance = String(localized: "Committed today: \(AppSettings.formatUSD(committed))", bundle: .module)
        case .account(let info):
            balance = info.credits.map {
                String(localized: "Credits left: \(ConnectionState.grouped($0, locale: locale))", bundle: .module)
            }
        }
    }

    /// What VoiceOver reads for the status item: "Jutsu Studio, 2 active jobs".
    public static func accessibilityLabel(activeCount: Int) -> String {
        switch activeCount {
        case ...0: String(localized: "Jutsu Studio, no active jobs", bundle: .module)
        case let count: String(localized: "Jutsu Studio, \(count) active jobs", bundle: .module)
        }
    }

    /// The number next to the status item icon; `nil` when the setting is off or nothing runs.
    public static func countText(activeCount: Int, isShown: Bool) -> String? {
        isShown && activeCount > 0 ? String(activeCount) : nil
    }

    static func headline(active: Int, paused: Int) -> String {
        guard active > 0 else { return String(localized: "No jobs in the queue", bundle: .module) }
        let count = String(localized: "\(active) jobs in the queue", bundle: .module)
        return paused > 0 ? "\(count) · " + String(localized: "\(paused) paused", bundle: .module) : count
    }
}
