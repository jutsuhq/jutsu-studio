import Foundation
import JutsuCore

// The spending guard of agents' jobs (`Job.agent`): checked right before every paid submit, never by the agent.
extension JobEngine {
    /// What `clearAgentSpend` lets the submit do.
    enum AgentClearance {
        /// Send it; the ledger entry it holds, `nil` for a job no agent queued or a submit already reserved.
        case send(reservation: UUID?)
        /// The job paused; send nothing.
        case paused
    }

    /// Runs right before an agent's job is sent, once its slot is taken: the person's own daily cap, strictly, then
    /// the agent's `max_cost`, an unknown price and today's agent budget (`AgentSpendDecision`), and last the
    /// reservation, written to the ledger before anything is sent. A job the plan's unlimited allowance pays for
    /// skips the cap and the budget, which don't count it, but goes out only when the person lets agents use the
    /// allowance (`AgentSpendPolicy.allowsUnlimited`); it reserves 0, and the charge the answer reports replaces that.
    /// Once such a job was charged anyway today (`AgentSpendTotal.unlimitedCharged`), the allowance is no longer
    /// trusted to pay: until the day ends, agents' jobs for it keep the cap, `max_cost` and the budget like any other.
    /// Over any limit, or when the ledger can't be read or written, the job pauses (`priceAboveCap` or `agentLimit`)
    /// and only the person resumes it (the agent may raise `max_cost` alone, `raiseAgentMaxCost`). A submit that may
    /// already have reached the server is resent with the reservation it holds and no new check.
    func clearAgentSpend(_ id: UUID, inputs: RemoteInputs) async throws -> AgentClearance {
        let job = try await loadJob(id)
        guard let origin = job.agent, job.submitAttempt == nil else { return .send(reservation: nil) }
        guard let agentPolicy else { return try await holdAgentJob(id, .ledgerUnavailable, inputs: inputs) }
        let allowsUnlimited = agentPolicy.allowsUnlimited()
        var chargedToday = false
        if job.spec.usesUnlimited, allowsUnlimited {
            do {
                chargedToday = try await agentPolicy.ledger.total(on: clock.now, unit: origin.maxCost.unit)
                    .unlimitedCharged
            } catch {
                log.error("Job \(id): the agent spend ledger can't be read", detail: String(describing: error))
                return try await holdAgentJob(id, .ledgerUnavailable, inputs: inputs)
            }
        }
        let unlimited = AgentSpendDecision.paysUnlimited(
            job.spec.usesUnlimited, allowsUnlimited: allowsUnlimited, chargedToday: chargedToday)
        if !unlimited, let status = try await spendStatus(job), let cap = status.cap,
            Budget.allows(cost: job.price, committedToday: status.committedToday, cap: cap) != .allowed,
            !Budget.covers(approved: job.approvedPrice, job.price)
        {
            try await apply(.paused(.priceAboveCap), to: id) { $0.inputs = inputs }
            return .paused
        }
        let decision = AgentSpendDecision.decide(
            price: job.price, isKnown: job.agentPriceIsKnown, origin: origin,
            dailyLimit: agentPolicy.dailyLimit(job.providerKind), paysUnlimited: unlimited,
            allowsUnlimited: allowsUnlimited, approved: job.approvedPrice)
        switch decision {
        case .hold(let hold):
            return try await holdAgentJob(id, hold, inputs: inputs)
        case .send(let money, let limit):
            let spend = AgentSpend(jobID: id, money: money, at: clock.now, paysUnlimited: unlimited)
            let fits: Bool
            do {
                fits = try await agentPolicy.ledger.reserve(spend, dailyLimit: limit)
            } catch {
                log.error("Job \(id): the agent spend ledger can't be written", detail: String(describing: error))
                return try await holdAgentJob(id, .ledgerUnavailable, inputs: inputs)
            }
            guard fits else { return try await holdAgentJob(id, .overDailyBudget, inputs: inputs) }
            return .send(reservation: spend.id)
        }
    }

    /// An agent's own job held because its price is above `max_cost`, sent again by the agent with a higher one:
    /// checked as the guard would check it now, the person's cap first, then the new `max_cost` and what is left of
    /// today's agent budget. When it fits, the job goes on with the new `max_cost` and no approval, so the guard
    /// checks it again in full right before its submit. Holds for any other reason stay for the person.
    public func raiseAgentMaxCost(_ id: UUID, to maxCost: AgentMoney) async throws -> AgentMaxCostRaise {
        guard Self.mayRaise(try await loadJob(id), to: maxCost) else { return .notLiftable }
        let job = try await loadJob(id)
        guard let agentPolicy, var origin = job.agent else { return .held(.ledgerUnavailable) }
        if let status = try await spendStatus(job), let cap = status.cap,
            Budget.allows(cost: job.price, committedToday: status.committedToday, cap: cap) != .allowed
        {
            return .overCap
        }
        let remaining: Int
        do {
            remaining = try await agentPolicy.ledger.total(on: clock.now, unit: maxCost.unit)
                .remaining(of: agentPolicy.dailyLimit(job.providerKind))
        } catch {
            log.error("Job \(id): the agent spend ledger can't be read", detail: String(describing: error))
            return .held(.ledgerUnavailable)
        }
        origin.maxCost = maxCost
        let decision = AgentSpendDecision.decide(
            price: job.price, isKnown: job.agentPriceIsKnown, origin: origin, dailyLimit: remaining)
        if case .hold(let hold) = decision { return .held(hold) }
        // The reads above let the person's Resume or the same raise sent again act on the job meanwhile, and a save
        // of theirs still in flight isn't in `jobs` yet: checked again within the write turn.
        let lifted = try await apply(.resume, to: id, ifStill: { Self.mayRaise($0, to: maxCost) }) {
            $0.agent?.maxCost = maxCost
            $0.agent?.hold = nil
        }
        guard lifted != nil else { return .notLiftable }
        log.notice("Job \(id): the agent raised its max_cost above the price; it goes on")
        startRunner(id)
        return .lifted
    }

    private static func mayRaise(_ job: Job, to maxCost: AgentMoney) -> Bool {
        guard job.state == .paused(.agentLimit), let origin = job.agent, origin.hold == .overMaxCost,
            !origin.approvedByPerson, job.submitAttempt == nil, job.remote == nil, !job.spec.usesUnlimited
        else { return false }
        return maxCost.unit == origin.maxCost.unit && maxCost.amount > origin.maxCost.amount
    }

    private func holdAgentJob(_ id: UUID, _ hold: AgentHold, inputs: RemoteInputs) async throws -> AgentClearance {
        log.notice("Job \(id): an agent's job is held, \(hold.rawValue)")
        try await apply(.paused(.agentLimit), to: id) {
            $0.inputs = inputs
            $0.agent?.hold = hold
        }
        return .paused
    }

    /// Gives back the reservations a crash orphaned: saved to the ledger, but the app stopped before the job saved
    /// it with its submit marker (`beginSubmit`), so nothing was sent. A reservation whose job holds it, or whose job
    /// has a submit marker, may have been sent and stays; so does one whose job isn't in the store (an image
    /// request, reconciled by its own log, or a job the store can't read). Runs at launch, before any job runs.
    func reconcileAgentReservations() async {
        guard let ledger = agentPolicy?.ledger else { return }
        let reservations: [AgentSpend]
        do {
            reservations = try await ledger.unsettled()
        } catch {
            log.error("The agent spend ledger can't be read to reconcile it", detail: String(describing: error))
            return
        }
        for spend in reservations {
            guard let job = try? await repository.job(id: spend.jobID), job.agent?.reservation != spend.id,
                job.submitAttempt == nil
            else { continue }
            log.error("Job \(job.id): released an agent reservation its submit never took")
            await releaseAgentSpend(spend.id, of: job.id)
        }
    }

    /// Gives back a reservation whose submit certainly never reached the provider. A ledger that can't be written
    /// keeps it, which only counts too much.
    func releaseAgentSpend(_ reservation: UUID?, of id: UUID) async {
        guard let reservation, let ledger = agentPolicy?.ledger else { return }
        do {
            try await ledger.release(reservation)
        } catch {
            log.error("Job \(id): an agent reservation can't be released", detail: String(describing: error))
        }
    }

    /// Keeps counting, at the amount reserved, a reservation the job lets go of: a retry starts a new attempt, and a
    /// new submit reserves anew. A reservation that certainly sent nothing is released and taken off the job when
    /// that is known (`settleFailedSubmit`, `beginSubmit`), so one the job still holds may have reached the provider
    /// (cut off, unanswered, a submit without an idempotency key) and may have been charged. Settling it also keeps
    /// the launch from giving it back once no job holds it (`reconcileAgentReservations`). Throws when the ledger
    /// can't be written, so the job keeps holding it.
    func keepAgentSpend(_ reservation: UUID?, of id: UUID) async throws {
        guard let reservation, let ledger = agentPolicy?.ledger else { return }
        do {
            try await ledger.settle(reservation, amount: nil)
        } catch {
            log.error("Job \(id): an agent's earlier charge can't be recorded", detail: String(describing: error))
            throw error
        }
    }

    /// Replaces the reservation of an answered submit with what it charged, else keeps the reserved amount.
    func settleAgentSpend(of job: Job, charged: Cost?) async {
        guard let reservation = job.agent?.reservation, let ledger = agentPolicy?.ledger else { return }
        do {
            if let charged, let money = AgentMoney(charged) {
                try await ledger.settle(reservation, amount: money.amount)
            } else {
                try await ledger.settle(reservation, amount: nil)
            }
        } catch {
            log.error("Job \(job.id): an agent's charge can't be recorded", detail: String(describing: error))
        }
    }

    /// The job ended in a way Higgsfield doesn't bill (its generation failed, moderation refused it, or it was
    /// cancelled before it ran): its share of its submit's ledger entry stops counting, all of it for a submit of one
    /// job. Only called once the provider said so; a job whose outcome isn't known (cut off, past the deadline,
    /// unanswered) never comes here and keeps counting. A ledger that can't be written keeps it, which only counts
    /// too much.
    func unbillAgentSpend(of id: UUID) async {
        guard let origin = jobs[id]?.agent, let entry = origin.ledgerEntry, let ledger = agentPolicy?.ledger else {
            return
        }
        do {
            try await ledger.unbill(entry, part: id.uuidString, of: origin.paidParts ?? 1)
        } catch {
            log.error("Job \(id): an agent's unbilled job can't be recorded", detail: String(describing: error))
        }
    }

    /// Marks the submit as begun and saves its marker with the agent's reservation. A stopping engine sends
    /// nothing new, and anything that stops the send here releases the reservation, as nothing was sent. A
    /// reservation of an earlier submit the job still holds keeps counting (`keepAgentSpend`). The caller finishes
    /// the submit once this returns.
    func beginSubmit(_ id: UUID, isIdempotent: Bool, reservation: UUID?) async throws {
        guard !Task.isCancelled, submits.begin(id) else {
            await releaseAgentSpend(reservation, of: id)
            throw CancellationError()
        }
        do {
            if let reservation, let earlier = jobs[id]?.agent?.reservation, earlier != reservation {
                try await keepAgentSpend(earlier, of: id)
            }
            try await save(id) {
                $0.submitAttempt = SubmitAttempt(isIdempotent: isIdempotent)
                if let reservation { $0.agent?.reservation = reservation }
            }
        } catch {
            submits.finish(id)
            await releaseAgentSpend(reservation, of: id)
            throw error
        }
    }
}
