import Foundation

public enum BudgetError: Error, LocalizedError {
    case spendingUnavailable

    public var errorDescription: String? {
        String(
            localized:
                "Today's spending couldn't be read. Nothing was sent. Repair the spending data or turn off the daily cap in Settings.",
            bundle: .module)
    }
}

public enum BudgetDecision: Sendable, Hashable {
    case allowed
    /// Starting the job would take today's spend over the cap, in the cap's unit.
    case needsConfirmation(total: Decimal)
}

/// A soft daily limit: USD for an API key, credits for a Higgsfield account.
public struct SpendCap: Sendable, Hashable {
    public var amount: Decimal
    public var unit: Capabilities.CostUnit

    public init(amount: Decimal, unit: Capabilities.CostUnit) {
        self.amount = amount
        self.unit = unit
    }

    public static func usd(_ amount: Decimal) -> SpendCap { SpendCap(amount: amount, unit: .usd) }
    public static func credits(_ amount: Int) -> SpendCap { SpendCap(amount: Decimal(amount), unit: .credits) }
}

/// Daily spend cap. A cap limits only costs in its own unit.
public enum Budget {
    /// - Parameters:
    ///   - committedToday: spend in the cap's unit of jobs finished today plus every job in flight,
    ///     so queueing can't bypass the cap.
    ///   - cap: `nil` when the user has no cap.
    public static func allows(cost: Cost, committedToday: Decimal, cap: SpendCap?) -> BudgetDecision {
        guard let cap, cost.unit == cap.unit else { return .allowed }
        let total = committedToday + cost.amount
        // An unknown price (`Cost.isUnknownPrice`) reads as 0, which would always fit: it asks instead.
        return total > cap.amount || cost.isUnknownPrice ? .needsConfirmation(total: total) : .allowed
    }

    /// Whether a price quoted after queueing has to go back to the user: only when it takes the job over the cap and
    /// is more than the user agreed to: `approved` when they agreed to a price over the cap, else the preliminary
    /// price as long as that one fit.
    /// - Parameter committedToday: as in `allows`, without the job itself.
    public static func refinedPriceNeedsConfirmation(
        preliminary: Cost, refined: Cost, approved: Cost?, committedToday: Decimal, cap: SpendCap?
    ) -> Bool {
        if covers(approved: approved, refined) { return false }
        guard case .needsConfirmation = allows(cost: refined, committedToday: committedToday, cap: cap) else {
            return false
        }
        if let approved, approved.unit == refined.unit { return true }
        return allows(cost: preliminary, committedToday: committedToday, cap: cap) == .allowed
    }

    /// Whether the price the person agreed to, `approved`, covers `price`: in the same unit and no lower.
    public static func covers(approved: Cost?, _ price: Cost) -> Bool {
        guard let approved, approved.unit == price.unit else { return false }
        return price.amount <= approved.amount
    }

    /// Spend in `unit` committed on `day`: jobs charged that day plus every job still in the queue, so queueing
    /// can't bypass the cap. Failed and canceled jobs count when the API finished them, or when it may have
    /// (`Job.mayHaveBeenCharged`), on the day they ended. Each job counts at `Job.price`, the server's quote once
    /// there is one. A job paid from the plan's unlimited allowance (`JobSpec.usesUnlimited`) doesn't count.
    public static func committed(
        _ jobs: [Job], on day: Date, in unit: Capabilities.CostUnit, calendar: Calendar = .current
    ) -> Decimal {
        jobs.reduce(Decimal(0)) { total, job in
            guard job.price.unit == unit, !job.spec.usesUnlimited else { return total }
            if job.state.isActive { return total + job.price.amount }
            guard job.isCharged || job.mayHaveBeenCharged, let charged = job.chargedAt ?? job.finishedAt,
                calendar.isDate(charged, inSameDayAs: day)
            else { return total }
            return total + job.price.amount
        }
    }
}

/// What the daily cap counts at the moment a job is about to be submitted.
public struct SpendStatus: Sendable, Hashable {
    /// Spend in the cap's unit of every other job the cap counts today.
    public var committedToday: Decimal
    /// `nil` when the user has no cap.
    public var cap: SpendCap?

    public init(committedToday: Decimal, cap: SpendCap?) {
        self.committedToday = committedToday
        self.cap = cap
    }
}
