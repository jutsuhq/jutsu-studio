import Foundation
import JutsuCore

// The money, times and durations a Queue row shows.

extension JobRowModel {
    /// The plan's unlimited generations, "Price unknown" for an operation no answer priced, else `format`.
    static func costText(_ job: Job, charged: Bool) -> String {
        if job.spec.usesUnlimited { return CostText.unlimited }
        if job.priceIsUnknown, charged { return PostOperationText.priceUnknown }
        return format(job.price, charged: charged)
    }

    /// "$8.17" or "16 cr"; zero in the job's unit when it was not charged. Estimates get a "~".
    static func format(_ cost: Cost, charged: Bool) -> String {
        switch cost {
        case .usd(let amount, let isEstimate):
            guard charged else { return CostText.dollars(0) }
            return (isEstimate ? "~" : "") + CostText.dollars(amount)
        case .credits(let amount, let isEstimate):
            guard charged else { return CostText.credits(0) }
            return (isEstimate ? "~" : "") + CostText.credits(amount)
        }
    }

    /// "mm:ss.t", as on the trim strip: 12.04 s → "00:12.0".
    static func timecode(_ seconds: TimeInterval) -> String {
        CostText.timecode(seconds)
    }

    /// "0:42", "12:05", "1:02:09".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        let tail = (rest < 10 ? "0" : "") + "\(rest)"
        if hours > 0 { return "\(hours):\(minutes < 10 ? "0" : "")\(minutes):" + tail }
        return "\(minutes):" + tail
    }

    /// "~40 s", "~2 min", "~1 h 30 min": rounded so it doesn't read as a measurement.
    static func approximate(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        if total < 55 { return "~" + Self.seconds(max(10, Int((total / 10).rounded()) * 10)) }
        let minutes = Int((total / 60).rounded())
        if minutes < 60 { return "~" + Self.minutes(minutes) }
        let rest = minutes % 60
        return "~" + hours(minutes / 60) + (rest == 0 ? "" : " " + Self.minutes(rest))
    }

    /// "40 s", "1 min 40 s", "1 h 2 min".
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        if hours > 0 { return Self.hours(hours) + (minutes == 0 ? "" : " " + Self.minutes(minutes)) }
        if minutes > 0 { return Self.minutes(minutes) + (rest == 0 ? "" : " " + Self.seconds(rest)) }
        return Self.seconds(rest)
    }

    private static func hours(_ value: Int) -> String { String(localized: "\(value) h", bundle: .module) }
    private static func minutes(_ value: Int) -> String { String(localized: "\(value) min", bundle: .module) }
    private static func seconds(_ value: Int) -> String { String(localized: "\(value) s", bundle: .module) }

    /// "just now", "3 min ago", "2 h ago", "4 d ago".
    static func relativeTime(from date: Date, to now: Date) -> String {
        let minutes = now.timeIntervalSince(date) / 60
        if minutes < 1 { return String(localized: "just now", bundle: .module) }
        if minutes < 60 { return String(localized: "\(Int(minutes.rounded())) min ago", bundle: .module) }
        if minutes < 1440 { return String(localized: "\(Int((minutes / 60).rounded())) h ago", bundle: .module) }
        return String(localized: "\(Int((minutes / 1440).rounded())) d ago", bundle: .module)
    }
}
