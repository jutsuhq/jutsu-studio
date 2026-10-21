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
    /// A variant's: the ledger entry of the submit that started it, its sender's `reservation`. Cleared by a retry.
    public var paidBy: UUID?
    /// How many jobs the submit that started this one started, itself included, when it was more than one: each is
    /// that share of the entry (`AgentSpendLedger.unbill`). Cleared by a retry.
    public var paidParts: Int?
    /// An agent's `pause_queue` paused the job (`JobEngine.pauseAll(agentsOnly:)`), so its `resume_queue` may lift
    /// that pause; `nil` once the person's own Pause all took it over, or the job was resumed.
    // swiftlint:disable:next discouraged_optional_boolean
    public var pausedByAgent: Bool?

    public init(
        client: String?, requestID: String, maxCost: AgentMoney, reservation: UUID? = nil, hold: AgentHold? = nil,
        approvedByPerson: Bool = false, paidBy: UUID? = nil, paidParts: Int? = nil
    ) {
        self.client = client
        self.requestID = requestID
        self.maxCost = maxCost
        self.reservation = reservation
        self.hold = hold
        self.approvedByPerson = approvedByPerson
        self.paidBy = paidBy
        self.paidParts = paidParts
    }

    /// A retry, a new attempt: it forgets the person's approval, the hold and what paid for the attempt before.
    public mutating func startOver() {
        approvedByPerson = false
        hold = nil
        reservation = nil
        paidBy = nil
        paidParts = nil
        pausedByAgent = nil
    }

    /// The ledger entry this job's charge is part of: its own submit's, else its sender's.
    public var ledgerEntry: UUID? { reservation ?? paidBy }
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
    /// It would be paid from the plan's unlimited allowance, which Settings › Agents › Let agents use unlimited
    /// generations doesn't allow.
    case unlimitedNotAllowed
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
    /// How many equal parts `money` pays for (the jobs of a submit of variants, the jobs of an image request), once
    /// one of them ended unbilled; `nil` before.
    public var parts: Int?
    /// The parts that ended without being billed (`AgentSpendLedger.unbill`), each once.
    public var unbilled: [String]?

    public init(id: UUID = UUID(), jobID: UUID, money: AgentMoney, at: Date, isSettled: Bool = false) {
        self.id = id
        self.jobID = jobID
        self.money = money
        self.at = at
        self.isSettled = isSettled
    }

    /// The most parts an entry is split into: far above any request, and small enough that `counted` can't overflow.
    public static let maxParts = 1_000

    /// What it counts against the budget: `money`, less the share of the parts that ended unbilled, rounded up so a
    /// fraction is never read as free; 0 once every part did.
    public var counted: Int {
        guard let parts, parts > 0, let unbilled, !unbilled.isEmpty else { return money.amount }
        let billed = max(0, parts - unbilled.count)
        let (whole, rest) = money.amount.quotientAndRemainder(dividingBy: parts)
        return whole * billed + (rest * billed + parts - 1) / parts
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
    /// One of the `parts` jobs the submit `id` paid for ended without being billed: Higgsfield doesn't charge a
    /// generation that failed, was refused by moderation or was cancelled. From then on the entry counts only its
    /// billed parts' share (`AgentSpend.counted`), 0 when none is left; `part` names the job, and counts once. An
    /// entry the ledger no longer keeps is left alone.
    func unbill(_ id: UUID, part: String, of parts: Int) async throws
    /// What is taken on `day` in `unit`.
    func total(on day: Date, unit: AgentMoney.Unit) async throws -> AgentSpendTotal
    /// The reservations not settled yet, of every day the ledger keeps: what a launch reconciles with the jobs.
    func unsettled() async throws -> [AgentSpend]
}

/// What the spending guard decides before an agent's job is sent.
public enum AgentSpendDecision: Sendable, Hashable {
    /// Send it, reserving this much against the day's agent budget; `limit` is that budget, or `nil` when the person
    /// approved the job past it.
    case send(AgentMoney, limit: Int?)
    case hold(AgentHold)

    /// The guard's rule, without the reservation itself (`AgentSpendLedger.reserve` checks the budget as it saves).
    /// A request the plan's unlimited allowance pays costs the budgets nothing, so it goes out reserving 0 with no
    /// limit, but only when the person lets agents use the allowance (or sent it themselves); otherwise it is held.
    /// - Parameters:
    ///   - price: the job's best known price (`Job.price`).
    ///   - isKnown: the price is the provider's quote, or an exact list price rather than an estimate.
    ///   - dailyLimit: the person's daily agent budget for the connection, in `origin.maxCost`'s unit.
    ///   - paysUnlimited: the request is to be paid from the plan's unlimited allowance (`JobSpec.usesUnlimited`).
    ///   - allowsUnlimited: Settings › Agents › Let agents use unlimited generations.
    public static func decide(
        price: Cost, isKnown: Bool, origin: AgentOrigin, dailyLimit: Int, paysUnlimited: Bool = false,
        allowsUnlimited: Bool = false
    ) -> Self {
        if paysUnlimited {
            guard allowsUnlimited || origin.approvedByPerson else { return .hold(.unlimitedNotAllowed) }
            return .send(AgentMoney(0, origin.maxCost.unit), limit: nil)
        }
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
