import Foundation
import JutsuCore

extension CharacterQuote {
    /// The quote in fractional credits, never rounded down.
    public var price: String {
        LibraryFormat.credits(Decimal(credits), fractionDigits: 3, rounding: .up)
    }

    public var priceText: String {
        String(localized: "\(price) · Price from Higgsfield", bundle: .module)
    }
}

extension Job {
    /// Where `price` comes from: the preliminary estimate, or the provider's quote, for the uploaded inputs or, on
    /// the account, before upload (a credit price that isn't an estimate is a `get_cost` quote).
    public var priceSource: String {
        if spec.usesUnlimited { return String(localized: "Unlimited generations of the plan", bundle: .module) }
        if priceIsUnknown { return PostOperationText.chargedOnCompletion }
        return serverPrice == nil && (providerKind != .account || cost.isEstimate)
            ? String(localized: "Estimate", bundle: .module)
            : String(localized: "Price from Higgsfield", bundle: .module)
    }

    /// What the job counts as spent: `price`, or nothing when the plan's unlimited allowance pays for it.
    public var spentPrice: Cost {
        spec.usesUnlimited ? .credits(0, isEstimate: price.isEstimate) : price
    }
}

extension Cost {
    /// The sum, an estimate when any part is; `nil` for no costs or for costs in different units.
    public static func total(_ costs: [Cost]) -> Cost? {
        guard var total = costs.first else { return nil }
        for cost in costs.dropFirst() {
            switch (total, cost) {
            case (.usd(let sum, let wasEstimate), .usd(let amount, let isEstimate)):
                total = .usd(sum + amount, isEstimate: wasEstimate || isEstimate)
            case (.credits(let sum, let wasEstimate), .credits(let amount, let isEstimate)):
                total = .credits(sum + amount, isEstimate: wasEstimate || isEstimate)
            default:
                return nil
            }
        }
        return total
    }
}

/// How prices read in the UI: "$8.85", "$0.681", "96 cr".
public enum CostText {
    /// A job paid from the plan's unlimited allowance instead of credits.
    public static var unlimited: String { String(localized: "Unlimited", bundle: .module) }

    /// The locale dollar amounts, times, percentages and sizes are written in. Tests pin it with `$locale.withValue`
    /// so they don't depend on the Mac's region.
    @TaskLocal public static var locale = Locale.autoupdatingCurrent

    /// "Price unknown" for `Cost.isUnknownPrice`, never "$0.00" or "0 cr".
    public static func text(_ cost: Cost) -> String {
        if cost.isUnknownPrice { return PostOperationText.priceUnknown }
        return switch cost {
        case .usd(let amount, _): dollars(amount)
        case .credits(let amount, _): credits(amount)
        }
    }

    /// "96 cr" or "0.25 cr": the exact amount, up to three decimals rounded up so a price never looks lower. The
    /// amount goes in as text: `String(localized:)` would group an integer by the locale, and credit amounts are
    /// shown ungrouped.
    public static func credits(_ amount: Decimal) -> String {
        String(localized: "\(exactCredits(amount)) cr", bundle: .module)
    }

    /// "$8.85" or "96 credits".
    public static func amount(_ amount: Decimal, unit: Capabilities.CostUnit) -> String {
        switch unit {
        case .usd: dollars(amount)
        case .credits:
            if let whole = Int(exactly: NSDecimalNumber(decimal: amount).doubleValue), Decimal(whole) == amount {
                String(localized: "\(whole) credits", bundle: .module, locale: ungrouped)
            } else {
                String(localized: "\(exactCredits(amount)) credits", bundle: .module)
            }
        }
    }

    /// "4", "0.25", "1.125": with a point in every locale, so "1.125" never reads as 1125.
    static func exactCredits(_ amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 3, .up)
        return rounded.description
    }

    /// For the integers of credit amounts in `String(localized:)`, which otherwise groups them by the locale.
    static let ungrouped = Locale(identifier: "en_US_POSIX")

    /// Rounded half up to cents.
    /// `rounding` `.up` for a price that must never read lower than it is ("up to").
    public static func dollars(_ amount: Decimal, rounding: NSDecimalNumber.RoundingMode = .plain) -> String {
        usd(amount, digits: 2, rounding: rounding)
    }

    /// An image price: cents, or four decimals when cents would round it away (Soul 2 is $0.0032 an image).
    public static func imagePrice(_ cost: Cost) -> String {
        guard case .usd(let amount, _) = cost else { return text(cost) }
        var value = amount * 100
        var cents = Decimal()
        NSDecimalRound(&cents, &value, 0, .plain)
        return usd(amount, digits: cents == value ? 2 : 4)
    }

    /// Per-second rates keep three decimals, as the price table does.
    public static func rate(_ amount: Decimal, rounding: NSDecimalNumber.RoundingMode = .plain) -> String {
        usd(amount, digits: 3, rounding: rounding)
    }

    /// Always USD, which Higgsfield bills in, written the way `locale` writes it: "$1234.50" in en_US,
    /// "1234,50 $" in de_DE. Never grouped, which keeps prices short on the buttons and in the cost line.
    /// Rounded as a Decimal first: Decimal's own currency style ignores the currency on Linux.
    static func usd(
        _ amount: Decimal, digits: Int, rounding: NSDecimalNumber.RoundingMode = .plain,
        locale: Locale = CostText.locale
    ) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, digits, rounding)
        return NSDecimalNumber(decimal: rounded).doubleValue.formatted(
            .currency(code: "USD").locale(locale).precision(.fractionLength(digits)).grouping(.never))
    }

    /// "01:06.5": minutes and seconds with tenths, "01:06,5" where the locale writes a decimal comma.
    public static func timecode(_ seconds: TimeInterval) -> String {
        // Rounded to tenths first, half up, so the format style never rounds 0.05 differently.
        let tenths = Int((max(0, seconds) * 10).rounded())
        return Duration.milliseconds(tenths * 100).formatted(
            .time(pattern: .minuteSecond(padMinuteToLength: 2, fractionalSecondsLength: 1)).locale(locale))
    }

    /// "12.5 s".
    public static func seconds(_ value: TimeInterval) -> String {
        let number = value.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale))
        return String(localized: "\(number) s", bundle: .module)
    }

    /// "30 s", "4.5 s": a limit, without a trailing ".0".
    public static func limit(_ value: TimeInterval) -> String {
        let number = value.formatted(.number.precision(.significantDigits(1...6)).grouping(.never).locale(locale))
        return String(localized: "\(number) s", bundle: .module)
    }

    /// "42%" for a whole percentage, "42 %" where the locale spaces it.
    public static func percent(_ value: Int) -> String {
        value.formatted(.percent.locale(locale))
    }

    /// "42%" for 0.42, rounded half up.
    public static func percent(fraction: Double) -> String {
        percent(Int((fraction * 100).rounded()))
    }
}
