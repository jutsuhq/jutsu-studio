import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

/// An agent raising `max_cost` on its own job held above it: the job goes on only when the new `max_cost`, what is
/// left of today's agent budget and the person's cap all fit, and every other hold stays for the person.
@Suite(.timeLimit(.minutes(1)))
struct AgentMaxCostTests {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("agent-spend-\(UUID().uuidString).json")

    func ledger(_ harness: Harness) -> AgentSpendFile {
        AgentSpendFile(file: file, now: { [clock = harness.clock] in clock.now })
    }

    func policy(_ ledger: any AgentSpendLedger, limit: Int = 1_000) -> AgentSpendPolicy {
        AgentSpendPolicy(ledger: ledger, dailyLimit: { _ in limit }, allowsUnlimited: { false })
    }

    func origin(maxCents: Int) -> AgentOrigin {
        AgentOrigin(client: "claude-code", requestID: "r-1", maxCost: AgentMoney(maxCents, .usdCents))
    }

    func stored(_ id: UUID, in harness: Harness) async -> Job? {
        await harness.repository.snapshotJobs().first { $0.id == id }
    }

    /// The fake's list price is an exact $1.30, 130 cents.
    @Test func aMaxCostThatCoversThePriceLiftsTheHoldAndTheJobRuns() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))
        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 129))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))

        #expect(try await engine.raiseAgentMaxCost(job.id, to: AgentMoney(130, .usdCents)) == .lifted)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.agent?.maxCost == AgentMoney(130, .usdCents))
        #expect(done.agent?.approvedByPerson == false && done.agent?.hold == nil)
        #expect(harness.log.count("submit") == 1)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents).spent == 130)
    }

    @Test func aMaxCostStillBelowThePriceChangesNothing() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))
        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 100))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))

        #expect(try await engine.raiseAgentMaxCost(job.id, to: AgentMoney(129, .usdCents)) == .held(.overMaxCost))
        await quiesce()

        let held = await stored(job.id, in: harness)
        #expect(held?.state == .paused(.agentLimit) && held?.agent?.hold == .overMaxCost)
        #expect(held?.agent?.maxCost == AgentMoney(100, .usdCents))
        #expect(harness.log.count("submit") == 0)
    }

    /// What reservations and charges took today counts: the new max_cost fits, the rest of the budget doesn't.
    @Test func aPriceOverWhatIsLeftOfTheBudgetStaysHeld() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let taken = AgentSpend(jobID: UUID(), money: AgentMoney(100, .usdCents), at: harness.clock.now)
        #expect(try await ledger.reserve(taken, dailyLimit: nil))
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger, limit: 200))
        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 50))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))

        #expect(try await engine.raiseAgentMaxCost(job.id, to: AgentMoney(500, .usdCents)) == .held(.overDailyBudget))
        await quiesce()

        #expect(await stored(job.id, in: harness)?.state == .paused(.agentLimit))
        #expect(harness.log.count("submit") == 0)
    }

    @Test func thePersonsCapStillApplies() async throws {
        let harness = Harness()
        let raised = CallLog()
        let engine = try await harness.makeEngine(
            readSpend: { _ in
                SpendStatus(committedToday: raised.count("raise") > 0 ? 1.5 : 0, cap: .usd(2))
            }, agentPolicy: policy(ledger(harness)))
        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 50))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))

        raised.append("raise")
        #expect(try await engine.raiseAgentMaxCost(job.id, to: AgentMoney(500, .usdCents)) == .overCap)
        await quiesce()

        #expect(await stored(job.id, in: harness)?.state == .paused(.agentLimit))
        #expect(harness.log.count("submit") == 0)
    }

    /// A price not known, a lower or other-unit max_cost, or a job no longer held: nothing for the agent to lift.
    @Test func otherHoldsAndOtherAmountsAreNotLiftable() async throws {
        let harness = Harness()
        await harness.provider.setPreliminary(.usd(1, isEstimate: true))
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))
        let unknown = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 500))
        await harness.repository.wait(for: unknown.id, .paused(.agentLimit))
        #expect(await stored(unknown.id, in: harness)?.agent?.hold == .unknownPrice)

        #expect(try await engine.raiseAgentMaxCost(unknown.id, to: AgentMoney(900, .usdCents)) == .notLiftable)
        #expect(await stored(unknown.id, in: harness)?.state == .paused(.agentLimit))

        let quoted = Harness()
        let other = try await quoted.makeEngine(agentPolicy: policy(ledger(quoted)))
        let job = try await other.enqueue(makeSpec(), agent: origin(maxCents: 100))
        await quoted.repository.wait(for: job.id, .paused(.agentLimit))
        #expect(try await other.raiseAgentMaxCost(job.id, to: AgentMoney(90, .usdCents)) == .notLiftable)
        #expect(try await other.raiseAgentMaxCost(job.id, to: AgentMoney(100, .usdCents)) == .notLiftable)
        #expect(try await other.raiseAgentMaxCost(job.id, to: AgentMoney(500, .credits)) == .notLiftable)

        try await other.resume(job.id)
        await quoted.repository.wait(for: job.id, .done)
        #expect(try await other.raiseAgentMaxCost(job.id, to: AgentMoney(500, .usdCents)) == .notLiftable)
        #expect(quoted.log.count("submit") == 1)
    }

    /// The raise checks the budget as it is then; the guard checks it again right before the submit, so a job that
    /// took the rest of the budget meanwhile holds the lifted job again, with nothing sent.
    @Test func aLiftedJobIsHeldAgainWhenTheBudgetIsTakenBeforeItsSubmit() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger, limit: 200))
        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 129))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))
        let gates = await harness.repository.holdSave { $0.state == .preparing }

        async let raise = engine.raiseAgentMaxCost(job.id, to: AgentMoney(130, .usdCents))
        try await gates.reached.wait()
        let other = AgentSpend(jobID: UUID(), money: AgentMoney(100, .usdCents), at: harness.clock.now)
        #expect(try await ledger.reserve(other, dailyLimit: 200))
        await gates.release.open(.success(()))
        #expect(try await raise == .lifted)

        await harness.repository.wait { $0.jobs[job.id]?.agent?.hold == .overDailyBudget }
        let held = await stored(job.id, in: harness)
        #expect(held?.state == .paused(.agentLimit) && held?.agent?.maxCost == AgentMoney(130, .usdCents))
        #expect(harness.log.count("submit") == 0)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents).taken == 100)
    }

    /// The same raise sent again while the first one's save is still on its way: the second sees the lifted job only
    /// within its write turn, and answers not liftable instead of resuming a job that already goes on.
    @Test func aRaiseSentAgainWhileTheFirstIsSavedLiftsOnce() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))
        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 129))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))
        let gates = await harness.repository.holdSave { $0.state == .preparing }

        async let first = engine.raiseAgentMaxCost(job.id, to: AgentMoney(130, .usdCents))
        try await gates.reached.wait()
        async let second = engine.raiseAgentMaxCost(job.id, to: AgentMoney(130, .usdCents))
        // The second has to wait for the write turn while the first is held; nothing observable marks that.
        await quiesce()
        await gates.release.open(.success(()))

        #expect(try await Set([first, second]) == [.lifted, .notLiftable])
        let done = try #require(await harness.repository.wait(for: job.id, .done))
        #expect(done.agent?.maxCost == AgentMoney(130, .usdCents) && done.agent?.approvedByPerson == false)
        #expect(harness.log.count("submit") == 1)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents).spent == 130)
    }

    /// The person's Confirm while the agent's raise is being saved: the job goes on once, under the agent's raise.
    @Test func thePersonsResumeDuringARaiseLeavesTheLiftedJob() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))
        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 129))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))
        let gates = await harness.repository.holdSave { $0.state == .preparing }

        async let raise = engine.raiseAgentMaxCost(job.id, to: AgentMoney(130, .usdCents))
        try await gates.reached.wait()
        async let resume: Void = engine.resume(job.id)
        await quiesce()
        await gates.release.open(.success(()))

        #expect(try await raise == .lifted)
        try await resume
        let done = try #require(await harness.repository.wait(for: job.id, .done))
        #expect(done.agent?.approvedByPerson == false)
        #expect(harness.log.count("submit") == 1)
    }

    /// The agent's raise while the person's Confirm is being saved: the person decided, so nothing is lifted.
    @Test func aRaiseDuringThePersonsResumeIsNotLiftable() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))
        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 129))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))
        let gates = await harness.repository.holdSave { $0.state == .preparing }

        async let resume: Void = engine.resume(job.id)
        try await gates.reached.wait()
        async let raise = engine.raiseAgentMaxCost(job.id, to: AgentMoney(130, .usdCents))
        await quiesce()
        await gates.release.open(.success(()))

        try await resume
        #expect(try await raise == .notLiftable)
        let done = try #require(await harness.repository.wait(for: job.id, .done))
        #expect(done.agent?.approvedByPerson == true && done.agent?.maxCost == AgentMoney(129, .usdCents))
        #expect(harness.log.count("submit") == 1)
    }
}
