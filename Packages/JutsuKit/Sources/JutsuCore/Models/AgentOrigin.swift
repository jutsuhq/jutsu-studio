import Foundation

/// A job an AI agent queued through the `jutsu` helper, and what it may spend. Set when the job is queued and kept
/// by its variants; `nil` for every job the person queued, and in jobs stored before agents existed.
public struct AgentOrigin: Codable, Sendable, Hashable {
    /// The MCP client's own name ("claude-code"), as the helper reported it; `nil` when it gave none.
    public var client: String?
    /// The agent's `request_id`: the same request sent again returns this job instead of queueing another.
    public var requestID: String
    /// The most the agent agreed to pay for this job, in whole units of its connection.
    public var maxCost: AgentMoney
    /// The agent spend ledger's entry held for the submit in flight (`AgentSpendLedger.reserve`); `nil` before the
    /// first submit, and on variants, whose submit their sender's entry pays for.
    public var reservation: UUID?
    /// Why the spending guard paused the job (`PauseReason.agentLimit`); `nil` while it isn't paused for it.
    public var hold: AgentHold?
    /// The person resumed the job past an agent limit: it goes on at the price they saw, still under their own daily
    /// cap. Cleared by a retry, which is a new attempt.
    public var approvedByPerson: Bool

    public init(
        client: String?, requestID: String, maxCost: AgentMoney, reservation: UUID? = nil, hold: AgentHold? = nil,
        approvedByPerson: Bool = false
    ) {
        self.client = client
        self.requestID = requestID
        self.maxCost = maxCost
        self.reservation = reservation
        self.hold = hold
        self.approvedByPerson = approvedByPerson
    }
}

/// Why the spending guard stopped an agent's job before its submit. Only a person resumes it.
public enum AgentHold: String, Codable, Sendable, Hashable {
    /// Neither the provider nor the price list could say what it costs.
    case unknownPrice
    /// Its price is above the `max_cost` the agent sent.
    case overMaxCost
    /// Its price is more than is left of today's agent budget, reservations of submits in flight included.
    case overDailyBudget
    /// The agent spend ledger couldn't be read or written, so nothing an agent asks for is sent.
    case ledgerUnavailable
}

/// Whole cents or whole credits: what agent budgets and `max_cost` count in. Integers only, so a sum can't drift.
public struct AgentMoney: Codable, Sendable, Hashable {
    public enum Unit: String, Codable, Sendable, Hashable {
        case usdCents = "usd_cents"
        case credits
    }

    public var unit: Unit
    /// Never negative.
    public var amount: Int

    public init(_ amount: Int, _ unit: Unit) {
        self.unit = unit
        self.amount = max(0, amount)
    }

    /// The most any amount can be: far above any real price, and far enough below `Int.max` that sums of many of
    /// them can't overflow.
    public static let ceiling = 1 << 50

    /// What a connection's agent budget counts in: cents with an API key, credits on an account.
    public static func unit(for kind: ProviderKind) -> Unit {
        kind == .apiKey ? .usdCents : .credits
    }

    /// `cost` in whole units, rounded up so a fraction of a cent or credit is never read as free; `nil` for an
    /// unknown price (`Cost.isUnknownPrice`) or an amount that isn't a finite, non-negative number. Huge amounts are
    /// clamped to `ceiling` rather than trapping.
    public init?(_ cost: Cost) {
        guard !cost.isUnknownPrice else { return nil }
        var scaled = cost.unit == .usd ? cost.amount * 100 : cost.amount
        guard !scaled.isNaN, scaled >= 0 else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .up)
        let units = rounded >= Decimal(Self.ceiling) ? Self.ceiling : NSDecimalNumber(decimal: rounded).intValue
        self.init(units, cost.unit == .usd ? .usdCents : .credits)
    }

    /// `a + b`, stopping at `ceiling`.
    public static func sum(_ a: Int, _ b: Int) -> Int {
        let (total, overflow) = max(0, a).addingReportingOverflow(max(0, b))
        return overflow ? ceiling : min(total, ceiling)
    }
}

/// What agents took on one day, in one unit.
public struct AgentSpendTotal: Sendable, Hashable {
    /// Charged by submits that were answered.
    public var spent: Int
    /// Held for submits sent and not answered yet, or never known to be answered.
    public var reserved: Int

    public init(spent: Int = 0, reserved: Int = 0) {
        self.spent = spent
        self.reserved = reserved
    }

    public var taken: Int { AgentMoney.sum(spent, reserved) }

    /// What is left of `dailyLimit`, never below 0.
    public func remaining(of dailyLimit: Int) -> Int { max(0, dailyLimit - taken) }
}

/// One submit of an agent's job, as the ledger holds it.
public struct AgentSpend: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var jobID: UUID
    public var money: AgentMoney
    /// When it was reserved: the day it counts on.
    public var at: Date
    /// The submit was answered and `money` is what it charged; before that it is reserved.
    public var isSettled: Bool

    public init(id: UUID = UUID(), jobID: UUID, money: AgentMoney, at: Date, isSettled: Bool = false) {
        self.id = id
        self.jobID = jobID
        self.money = money
        self.at = at
        self.isSettled = isSettled
    }
}

/// The durable record of what agents spend, apart from the jobs: a job deleted from the library takes nothing back.
/// Every call throws when the record can't be read or written, and the engine then sends nothing for an agent.
public protocol AgentSpendLedger: Sendable {
    /// Saves `spend` as reserved if it fits under `dailyLimit` with everything else taken on its day in its unit;
    /// `nil` saves it whatever is taken. Returns `false`, saving nothing, when it doesn't fit. Checked and saved in
    /// one step, so two submits can't both take the last of the budget.
    func reserve(_ spend: AgentSpend, dailyLimit: Int?) async throws -> Bool
    /// Removes a reservation whose submit certainly never reached the provider.
    func release(_ id: UUID) async throws
    /// Marks a reservation as charged: what its submit charged, or `nil` for the amount reserved when the answer
    /// didn't say.
    func settle(_ id: UUID, amount: Int?) async throws
    /// What is taken on `day` in `unit`.
    func total(on day: Date, unit: AgentMoney.Unit) async throws -> AgentSpendTotal
}

/// What the spending guard decides before an agent's job is sent.
public enum AgentSpendDecision: Sendable, Hashable {
    /// Send it, reserving this much against the day's agent budget; `limit` is that budget, or `nil` when the person
    /// approved the job past it.
    case send(AgentMoney, limit: Int?)
    case hold(AgentHold)

    /// The guard's rule, without the reservation itself (`AgentSpendLedger.reserve` checks the budget as it saves).
    /// - Parameters:
    ///   - price: the job's best known price (`Job.price`).
    ///   - isKnown: the price is the provider's quote, or an exact list price rather than an estimate.
    ///   - dailyLimit: the person's daily agent budget for the connection, in `origin.maxCost`'s unit.
    public static func decide(price: Cost, isKnown: Bool, origin: AgentOrigin, dailyLimit: Int) -> Self {
        let money = AgentMoney(price)
        if origin.approvedByPerson { return .send(money ?? AgentMoney(0, origin.maxCost.unit), limit: nil) }
        guard isKnown, let money else { return .hold(.unknownPrice) }
        guard money.unit == origin.maxCost.unit, money.amount <= origin.maxCost.amount else {
            return .hold(.overMaxCost)
        }
        guard money.amount <= dailyLimit else { return .hold(.overDailyBudget) }
        return .send(money, limit: dailyLimit)
    }
}

extension Job {
    /// The price the guard may trust: the provider's quote, or an exact preliminary price.
    public var agentPriceIsKnown: Bool {
        !priceIsUnknown && (serverPrice != nil || !cost.isEstimate)
    }
}
