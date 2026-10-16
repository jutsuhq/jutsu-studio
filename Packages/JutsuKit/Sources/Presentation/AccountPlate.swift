import Foundation

/// The rank of a Higgsfield plan, which decides how its badge looks. Read from the plan's name, since plans get
/// renamed and added more often than they change rank.
public enum PlanTier: Int, Sendable, CaseIterable, Comparable {
    case free
    case starter
    case pro
    case premium
    case elite

    /// "Creator Plus" → `.elite`, "Pro" → `.pro`. An unknown paid plan counts as `.pro`.
    public init(planTitle: String) {
        let words = Set(planTitle.lowercased().split { !$0.isLetter }.map(String.init))
        func has(_ any: Set<String>) -> Bool { !words.isDisjoint(with: any) }
        if has(["ultra", "business", "team", "enterprise", "studio", "unlimited"])
            || words.isSuperset(of: ["creator", "plus"])
        {
            self = .elite
        } else if has(["ultimate", "creator", "premium", "max"]) {
            self = .premium
        } else if has(["pro", "plus", "standard"]) {
            self = .pro
        } else if has(["basic", "starter", "start", "lite"]) {
            self = .starter
        } else if has(["free", "trial"]) {
            self = .free
        } else {
            self = .pro
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The plate above Settings in the sidebar: the plan and what is left on it.
public struct AccountPlate: Sendable, Hashable {
    /// "Creator Plus", "Account" while the plan is unknown, "API key".
    public var badge: String
    /// `nil` for an API key and for an account whose plan isn't known yet: a neutral badge.
    public var tier: PlanTier?
    /// "2,596"; "—" while the credits are unknown.
    public var amount: String
    /// "credits", or what an API key is billed in.
    public var unit: String
    /// "Low credits: 42 left" below the threshold.
    public var warning: String?
    public var isAPIKey = false
    /// What `amount` shows, for the plural in `accessibilityLabel`.
    var credits: Int?
    var locale: Locale

    /// `nil` without a connection.
    public init?(connection: ConnectionState, lowCreditThreshold: Int, locale: Locale = .current) {
        self.locale = locale
        switch connection {
        case .none:
            return nil
        case .apiKey:
            badge = String(localized: "API key", bundle: .module)
            isAPIKey = true
            amount = String(localized: "Per job", bundle: .module)
            unit = String(localized: "billed in USD", bundle: .module)
        case .account(let info):
            badge = info.plan ?? String(localized: "Account", bundle: .module)
            tier = info.plan.map(PlanTier.init(planTitle:))
            credits = info.credits
            amount = info.credits.map { ConnectionState.grouped($0, locale: locale) } ?? "—"
            unit = String(localized: "credits", bundle: .module)
            warning = LowCreditWarning.text(for: connection, threshold: lowCreditThreshold, locale: locale)
        }
    }

    /// "Creator Plus plan, 2,596 credits left".
    public var accessibilityLabel: String {
        guard !isAPIKey else { return String(localized: "API key, billed in USD per job", bundle: .module) }
        switch (tier, credits) {
        case (nil, nil): return String(localized: "Higgsfield account", bundle: .module)
        case (nil, let credits?):
            return String(localized: "Higgsfield account, \(credits) credits left", bundle: .module, locale: locale)
        case (_?, nil): return String(localized: "\(badge) plan", bundle: .module)
        case (_?, let credits?):
            return String(localized: "\(badge) plan, \(credits) credits left", bundle: .module, locale: locale)
        }
    }
}
