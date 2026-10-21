import Foundation
import JutsuCore

/// Settings › Agents as the person saved it. `UserDefaults` also reads the argument domain, so anything that can
/// launch the app (`open --args -agents.allow YES`) could turn agents on or give them a budget by itself; a bundled
/// app therefore reads its persistent domain alone, which only the app's own Settings writes.
public struct AgentPreferences {
    public static let allowKey = "agents.allow"
    /// Integer cents, for an API key.
    public static let budgetCentsKey = "agents.dailyBudgetCents"
    /// Whole credits, for an account.
    public static let budgetCreditsKey = "agents.dailyBudgetCredits"
    /// The most a daily budget may be: $10,000, or ten million credits. Whatever is stored is read within these,
    /// so no sum of budgets and prices can overflow.
    public static let maxBudgetCents = 1_000_000
    public static let maxBudgetCredits = 10_000_000

    let defaults: UserDefaults
    /// The app's own defaults domain, its bundle ID; nil reads `defaults` as it is, for tests and previews.
    let domain: String?

    public init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domain = domain
    }

    /// Off until the person turns it on.
    public var isAllowed: Bool { stored(Self.allowKey) as? Bool ?? false }

    /// What agents may spend a day on `connection`, in its whole units: cents with an API key, credits on an
    /// account. 0 until the person sets one, so agents can look but not spend.
    public func dailyBudget(for connection: ProviderKind) -> Int {
        let (key, limit) = Self.budgetKey(for: connection)
        guard let number = stored(key) as? NSNumber else { return 0 }
        // Through Double, which holds any stored number without trapping, then clamped before it becomes an Int.
        let value = number.doubleValue
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(.down), 0), Double(limit)))
    }

    /// Settings › Agents writes these; `defaults` is the app's own domain, so they are read back as saved.
    public func setAllowed(_ isAllowed: Bool) {
        defaults.set(isAllowed, forKey: Self.allowKey)
    }

    /// Stores `amount` within the most for `connection`.
    public func setDailyBudget(_ amount: Int, for connection: ProviderKind) {
        let (key, limit) = Self.budgetKey(for: connection)
        defaults.set(min(max(amount, 0), limit), forKey: key)
    }

    public static func budgetKey(for connection: ProviderKind) -> (key: String, limit: Int) {
        switch connection {
        case .apiKey: (budgetCentsKey, maxBudgetCents)
        case .account: (budgetCreditsKey, maxBudgetCredits)
        }
    }

    private func stored(_ key: String) -> Any? {
        guard let domain else { return defaults.object(forKey: key) }
        return defaults.persistentDomain(forName: domain)?[key]
    }

    // MARK: Text

    /// A budget as typed: dollars with at most two decimals ("12", "12.5", "$1,000.00") for an API key, whole credits
    /// ("1000", "1,000 credits") for an account; 0 is a budget too. nil for anything else or above the most, and the
    /// field keeps the last value. Read digit by digit, never through a floating-point number, so no input can
    /// overflow or round.
    public static func parseBudget(_ text: String, for connection: ProviderKind) -> Int? {
        var cleaned = text.lowercased().filter { !$0.isWhitespace && $0 != "," }
        switch connection {
        case .apiKey:
            if cleaned.hasPrefix("$") { cleaned.removeFirst() }
            let parts = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard let whole = parts.first, let dollars = digits(whole, upTo: 7) else { return nil }
            var cents = 0
            if parts.count == 2 {
                let fraction = parts[1]
                guard fraction.count <= 2, let value = digits(fraction, upTo: 2, allowsEmpty: true) else { return nil }
                cents = fraction.count == 1 ? value * 10 : value
            }
            let total = dollars * 100 + cents
            return total <= maxBudgetCents ? total : nil
        case .account:
            for suffix in ["credits", "credit", "cr"] where cleaned.hasSuffix(suffix) {
                cleaned.removeLast(suffix.count)
                break
            }
            guard let credits = digits(Substring(cleaned), upTo: 8) else { return nil }
            return credits <= maxBudgetCredits ? credits : nil
        }
    }

    /// The text `parseBudget` reads back: "12.50" or "1000".
    public static func budgetText(_ amount: Int, for connection: ProviderKind) -> String {
        switch connection {
        case .apiKey: String(format: "%d.%02d", amount / 100, amount % 100)
        case .account: String(amount)
        }
    }

    /// The value of up to `count` ASCII digits; nil for none (unless `allowsEmpty`), more, or anything else.
    private static func digits(_ text: Substring, upTo count: Int, allowsEmpty: Bool = false) -> Int? {
        guard text.count <= count, allowsEmpty || !text.isEmpty else { return nil }
        var value = 0
        for character in text {
            guard let digit = character.asciiValue, (48...57).contains(digit) else { return nil }
            value = value * 10 + Int(digit - 48)
        }
        return value
    }
}
