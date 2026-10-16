import Foundation
import JutsuCore

/// Text formats shared by the library card and details page. Locale-independent, like the prototype.
public enum LibraryFormat {
    /// "$1.91" or "24 cr".
    public static func cost(_ cost: Cost) -> String {
        if cost.isUnknownPrice { return PostOperationText.priceUnknown }
        return switch cost {
        case .usd(let amount, _): usd(amount, fractionDigits: 2)
        case .credits(let amount, _): CostText.credits(amount)
        }
    }

    public static func usd(_ amount: Decimal, fractionDigits: Int) -> String {
        CostText.usd(amount, digits: fractionDigits)
    }

    /// "4 cr", or "4.5 cr" when the amount isn't whole: always with a point, so "1.125 cr" never reads as 1125.
    public static func credits(
        _ amount: Decimal, fractionDigits: Int = 2, rounding: NSDecimalNumber.RoundingMode = .plain
    ) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, fractionDigits, rounding)
        return String(localized: "\(rounded.description) cr", bundle: .module)
    }

    /// "just now", "36 min ago", "2 h ago", "3 d ago"; a date after `now` is "just now".
    public static func ago(_ date: Date, now: Date) -> String {
        JobRowModel.relativeTime(from: date, to: now)
    }

    /// "01:04.5": minutes and seconds with one decimal.
    public static func timecode(_ seconds: TimeInterval) -> String {
        CostText.timecode(seconds)
    }
}
