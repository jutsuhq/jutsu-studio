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
    /// reservation, written to the ledger before anything is sent. Over any limit, or when the ledger can't be read
    /// or written, the job pauses (`priceAboveCap` or `agentLimit`) and only the person resumes it. A submit that may
    /// already have reached the server is resent with the reservation it holds and no new check.
    func clearAgentSpend(_ id: UUID, inputs: RemoteInputs) async throws -> AgentClearance {
        let job = try await loadJob(id)
        guard let origin = job.agent, job.submitAttempt == nil else { return .send(reservation: nil) }
        guard let agentPolicy else { return try await holdAgentJob(id, .ledgerUnavailable, inputs: inputs) }
        // A job the plan's unlimited allowance pays costs nothing the budgets count.
        let price = job.spec.usesUnlimited ? Cost.credits(0, isEstimate: false) : job.price
        if !job.spec.usesUnlimited, let status = try await spendStatus(job), let cap = status.cap,
            Budget.allows(cost: price, committedToday: status.committedToday, cap: cap) != .allowed,
            !Self.covers(job.approvedPrice, price)
        {
            try await apply(.paused(.priceAboveCap), to: id) { $0.inputs = inputs }
            return .paused
        }
        let decision = AgentSpendDecision.decide(
            price: price, isKnown: job.spec.usesUnlimited || job.agentPriceIsKnown, origin: origin,
            dailyLimit: agentPolicy.dailyLimit(job.providerKind))
        switch decision {
        case .hold(let hold):
            return try await holdAgentJob(id, hold, inputs: inputs)
        case .send(let money, let limit):
            let spend = AgentSpend(jobID: id, money: money, at: clock.now)
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

    /// The price the person agreed to covers `price`.
    private static func covers(_ approved: Cost?, _ price: Cost) -> Bool {
        guard let approved, approved.unit == price.unit else { return false }
        return price.amount <= approved.amount
    }

    private func holdAgentJob(_ id: UUID, _ hold: AgentHold, inputs: RemoteInputs) async throws -> AgentClearance {
        log.error("Job \(id): an agent's job is held, \(hold.rawValue)")
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

    /// Marks the submit as begun and saves its marker with the agent's reservation. A stopping engine sends
    /// nothing new, and anything that stops the send here releases the reservation, as nothing was sent. The
    /// caller finishes the submit once this returns.
    func beginSubmit(_ id: UUID, isIdempotent: Bool, reservation: UUID?) async throws {
        guard !Task.isCancelled, submits.begin(id) else {
            await releaseAgentSpend(reservation, of: id)
            throw CancellationError()
        }
        do {
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
