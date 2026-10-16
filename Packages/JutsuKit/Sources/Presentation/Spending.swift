import Foundation
import JutsuCore

public enum SpendingPeriod: String, CaseIterable, Sendable, Identifiable {
    case today, week, month

    public var id: Self { self }

    public var title: String {
        switch self {
        case .today: String(localized: "Today", bundle: .module)
        case .week: String(localized: "7 days", bundle: .module)
        case .month: String(localized: "30 days", bundle: .module)
        }
    }

    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    /// Midnight in `calendar`'s time zone, `days - 1` days before `now`; today counts as the first day.
    public func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }
}

/// USD and credits side by side: a job is paid in one of them and they never add up.
public struct SpendTotal: Sendable, Hashable {
    public var usd: Decimal = 0
    public var credits: Decimal = 0

    public init(usd: Decimal = 0, credits: Decimal = 0) {
        self.usd = usd
        self.credits = credits
    }

    mutating func add(_ cost: Cost) {
        switch cost {
        case .usd(let amount, _): usd += amount
        case .credits(let amount, _): credits += amount
        }
    }

    mutating func add(_ total: SpendTotal) {
        usd += total.usd
        credits += total.credits
    }

    /// "$12.40 · 96 cr", one unit when the other is unused, "$0.00" when nothing was spent.
    public var text: String {
        var parts: [String] = []
        if usd != 0 || credits == 0 { parts.append(CostText.dollars(usd)) }
        if credits != 0 { parts.append(CostText.text(.credits(credits, isEstimate: true))) }
        return parts.joined(separator: " · ")
    }
}

/// One row of a breakdown: charged jobs of one mode, resolution or kind.
public struct SpendLine: Sendable, Hashable, Identifiable {
    public var title: String
    public var jobs: Int
    public var total: SpendTotal

    public var id: String { title }

    public var jobsText: String { Self.jobsText(jobs) }

    /// "1 job", "3 jobs".
    public static func jobsText(_ count: Int) -> String {
        String(localized: "\(count) jobs", bundle: .module)
    }
}

/// Finished jobs of one period. Amounts are the estimates made before submit: the API doesn't report
/// what it actually charged.
public struct SpendingSummary: Sendable, Hashable {
    public var charged = SpendTotal()
    public var chargedJobs = 0
    /// Failed, rejected and canceled before the API finished them.
    public var notCharged = SpendTotal()
    public var notChargedJobs = 0
    public var byMode: [SpendLine] = []
    public var byResolution: [SpendLine] = []
    public var byKind: [SpendLine] = []

    /// Terminal jobs that finished in `period`, counted in `calendar`'s time zone, and the finished reference image
    /// requests and virality scores sent in it, which are charged and get a line each of their own in `byMode`.
    public init(
        _ jobs: [Job], images: [ImageCharge] = [], period: SpendingPeriod, now: Date, calendar: Calendar = .current
    ) {
        let start = period.start(now: now, calendar: calendar)
        let finished = jobs.filter { job in
            guard job.state.isTerminal, let finishedAt = job.finishedAt else { return false }
            return finishedAt >= start
        }
        var charged: [Job] = []
        for job in finished {
            if job.isCharged {
                charged.append(job)
                self.charged.add(job.spentPrice)
            } else {
                notCharged.add(job.spentPrice)
            }
        }
        chargedJobs = charged.count
        notChargedJobs = finished.count - charged.count
        byMode = Self.lines(charged, keys: Mode.allCases, key: \.spec.mode, title: \.title)
        let requests = images.filter { !$0.isPending && $0.date >= start }
        for purpose in [ImageCharge.Purpose.referenceImages, .characterSheets, .viralityScore] {
            let charges = requests.filter { $0.paidFor == purpose }
            guard !charges.isEmpty else { continue }
            var total = SpendTotal()
            for charge in charges { total.add(charge.cost) }
            self.charged.add(total)
            byMode.append(SpendLine(title: SpendingCSV.title(of: purpose), jobs: charges.count, total: total))
        }
        byResolution = Self.lines(charged, keys: Resolution.allCases, key: \.spec.resolution, title: \.rawValue)
        byKind = Self.lines(charged, keys: [true, false], key: \.spec.isDraft) {
            $0 ? String(localized: "Draft", bundle: .module) : String(localized: "Final", bundle: .module)
        }
    }

    /// One line per key that has jobs, in `keys` order.
    private static func lines<Key: Hashable>(
        _ jobs: [Job], keys: [Key], key: (Job) -> Key, title: (Key) -> String
    ) -> [SpendLine] {
        let groups = Dictionary(grouping: jobs, by: key)
        return keys.compactMap { value in
            guard let group = groups[value] else { return nil }
            var total = SpendTotal()
            for job in group { total.add(job.spentPrice) }
            return SpendLine(title: title(value), jobs: group.count, total: total)
        }
    }
}

/// The finished-jobs export: RFC 4180 (CRLF, quoted fields), ISO 8601 dates with the offset of `timeZone`.
public enum SpendingCSV {
    public static let header = [
        "Date", "Mode", "Resolution", "Draft", "Billed seconds", "Estimated cost", "Currency", "State", "Charged",
        "Request ID",
    ]

    /// The Mode of a reference image request's row, and its line in Spending.
    public static let referenceImagesTitle = String(localized: "Reference images", bundle: .module)
    /// The Mode of a virality score's row, and its line in Spending.
    public static let viralityScoresTitle = String(localized: "Virality scores", bundle: .module)
    /// The Mode of a character sheet request's row, and its line in Spending.
    public static let characterSheetsTitle = String(localized: "Character sheets", bundle: .module)

    static func title(of purpose: ImageCharge.Purpose) -> String {
        switch purpose {
        case .referenceImages: referenceImagesTitle
        case .viralityScore: viralityScoresTitle
        case .characterSheets: characterSheetsTitle
        }
    }

    /// Terminal jobs, finished reference image requests and virality scores, oldest first; a job is dated when it finished, a
    /// request when it was sent.
    public static func csv(_ jobs: [Job], images: [ImageCharge] = [], timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        let jobRows = jobs.filter(\.state.isTerminal).map { (date($0), row($0, formatter: formatter)) }
        let imageRows = images.filter { !$0.isPending }.map { ($0.date, row($0, formatter: formatter)) }
        let rows = (jobRows + imageRows).sorted { $0.0 < $1.0 }.map(\.1)
        return ([header] + rows).map(line).joined()
    }

    static func row(_ request: ImageCharge, formatter: ISO8601DateFormatter) -> [String] {
        let (amount, currency) =
            switch request.cost {
            case .usd(let usd, _): ("\(usd)", "USD")
            case .credits(let credits, _): ("\(credits)", "credits")
            }
        return [
            formatter.string(from: request.date), title(of: request.paidFor), "", "No", "0", amount, currency, "Done",
            "Yes", "",
        ]
    }

    static func row(_ job: Job, formatter: ISO8601DateFormatter) -> [String] {
        let amount: String
        let currency: String
        switch job.price {
        case .usd(let usd, _): (amount, currency) = ("\(usd)", "USD")
        case .credits(let credits, _): (amount, currency) = ("\(credits)", "credits")
        }
        return [
            formatter.string(from: date(job)), job.spec.mode.title, job.spec.resolution.rawValue,
            job.spec.isDraft ? "Yes" : "No", String(Pricing.billedSeconds(for: job.spec, on: job.providerKind)),
            amount, currency, stateTitle(job.state), job.isCharged ? "Yes" : "No", job.remote?.requestID ?? "",
        ]
    }

    static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\r\n"
    }

    /// Quotes a field holding a comma, quote or line break, doubling its quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func date(_ job: Job) -> Date { job.finishedAt ?? job.createdAt }

    private static func stateTitle(_ state: JobState) -> String {
        switch state {
        case .done: "Done"
        case .failed: "Failed"
        case .rejected: "Rejected"
        case .canceled: "Canceled"
        case .preparing, .uploading, .waitingForSlot, .queued, .processing, .downloading, .paused: "In queue"
        }
    }

    /// "Jutsu Studio spending 2025-10-13".
    public static func defaultFileName(now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = timeZone
        return "Jutsu Studio spending \(formatter.string(from: now))"
    }
}
