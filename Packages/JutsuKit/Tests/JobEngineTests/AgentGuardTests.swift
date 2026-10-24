import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

/// A ledger that refuses every write, as a full disk or a broken file would.
private struct BrokenLedger: AgentSpendLedger {
    struct Broken: Error {}

    func reserve(_ spend: AgentSpend, dailyLimit: Int?) throws -> Bool { throw Broken() }
    func release(_ id: UUID) throws { throw Broken() }
    func settle(_ id: UUID, amount: Int?) throws { throw Broken() }
    func unbill(_ id: UUID, part: String, of parts: Int) throws { throw Broken() }
    func total(on day: Date, unit: AgentMoney.Unit) throws -> AgentSpendTotal { throw Broken() }
    func unsettled() throws -> [AgentSpend] { throw Broken() }
}

/// The spending guard of agents' jobs: checked by the engine right before every paid submit.
@Suite(.timeLimit(.minutes(1)))
struct AgentGuardTests {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("agent-spend-\(UUID().uuidString).json")

    func ledger(_ harness: Harness) -> AgentSpendFile {
        AgentSpendFile(file: file, now: { [clock = harness.clock] in clock.now })
    }

    func policy(_ ledger: any AgentSpendLedger, limit: Int = 1_000, unlimited: Bool = false) -> AgentSpendPolicy {
        AgentSpendPolicy(ledger: ledger, dailyLimit: { _ in limit }, allowsUnlimited: { unlimited })
    }

    func origin(maxCents: Int = 500, request: String = "r-1") -> AgentOrigin {
        AgentOrigin(client: "claude-code", requestID: request, maxCost: AgentMoney(maxCents, .usdCents))
    }

    /// The fake's list price is an exact $1.30, 130 cents.
    @Test func aJobUnderEveryLimitIsSentAndItsChargeRecorded() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("submit") == 1)
        #expect(done.agent?.reservation != nil)
        let total = try await ledger.total(on: harness.clock.now, unit: .usdCents)
        #expect(total == AgentSpendTotal(spent: 130, reserved: 0))
    }

    /// A crash between the ledger's write and the job's: the job never held the reservation and has no submit
    /// marker, so nothing was sent and the launch gives it back. One the job holds stays, as does an image
    /// request's, whose job isn't in the store.
    @Test func aLaunchReleasesReservationsNoSubmitTook() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        var orphaned = Job(spec: makeSpec(), providerKind: .apiKey, cost: .usd(1.3, isEstimate: false))
        orphaned.state = .paused(.byUser)
        orphaned.agent = origin()
        var holding = Job(spec: makeSpec(), providerKind: .apiKey, cost: .usd(1.3, isEstimate: false))
        holding.state = .paused(.byUser)
        holding.agent = origin(request: "r-2")
        let held = AgentSpend(jobID: holding.id, money: AgentMoney(50, .usdCents), at: harness.clock.now)
        holding.agent?.reservation = held.id
        await harness.repository.save(orphaned)
        await harness.repository.save(holding)
        let lost = AgentSpend(jobID: orphaned.id, money: AgentMoney(130, .usdCents), at: harness.clock.now)
        let image = AgentSpend(jobID: UUID(), money: AgentMoney(7, .usdCents), at: harness.clock.now)
        for spend in [lost, held, image] { #expect(try await ledger.reserve(spend, dailyLimit: nil)) }

        _ = try await harness.makeEngine(agentPolicy: policy(ledger))

        #expect(
            try await ledger.unsettled().map(\.id).sorted { $0.uuidString < $1.uuidString }
                == [held.id, image.id].sorted { $0.uuidString < $1.uuidString })
        #expect(harness.log.count("submit") == 0)
    }

    @Test func aPriceOverMaxCostPausesWithoutSending() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 129))
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))

        #expect(paused.agent?.hold == .overMaxCost)
        #expect(harness.log.count("submit") == 0)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal())
    }

    /// A reservation in flight counts against the budget as much as a charge.
    @Test func reservationsInFlightCountAgainstTheDailyBudget() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let held = AgentSpend(jobID: UUID(), money: AgentMoney(100, .usdCents), at: harness.clock.now)
        #expect(try await ledger.reserve(held, dailyLimit: nil))
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger, limit: 200))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))

        #expect(paused.agent?.hold == .overDailyBudget)
        #expect(harness.log.count("submit") == 0)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents).reserved == 100)
    }

    @Test func noBudgetSetSendsNothing() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness), limit: 0))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))

        #expect(paused.agent?.hold == .overDailyBudget)
        #expect(harness.log.count("submit") == 0)
    }

    @Test(arguments: [Cost.unknownUSD, Cost.usd(1, isEstimate: true), Cost.credits(24, isEstimate: true)])
    func aPriceNotKnownPauses(preliminary: Cost) async throws {
        let harness = Harness()
        await harness.provider.setPreliminary(preliminary)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))

        #expect(paused.agent?.hold == .unknownPrice)
        #expect(harness.log.count("submit") == 0)
    }

    /// The server's quote right before submit is the price the guard checks.
    @Test func theServerQuoteIsWhatIsChecked() async throws {
        let harness = Harness()
        await harness.provider.setPreliminary(.usd(1, isEstimate: true))
        await harness.provider.setQuote(.success(.usd(6, isEstimate: false)))
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))

        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 500))
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))

        #expect(paused.agent?.hold == .overMaxCost)
        #expect(paused.serverPrice == .usd(6, isEstimate: false))
    }

    /// Only the person resumes a held job; it then goes past the agent's limits at the price they saw.
    @Test func thePersonsResumeSendsAHeldJobAndResumeAllDoesNot() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 10))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))
        await engine.resumeAll()
        await quiesce()
        #expect(await harness.repository.snapshotJobs().first { $0.id == job.id }?.state == .paused(.agentLimit))

        try await engine.resume(job.id)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.agent?.approvedByPerson == true)
        #expect(harness.log.count("submit") == 1)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents).spent == 130)
    }

    /// The person approved the price they saw; a quote that came only after that and is higher waits for them again.
    @Test func aQuoteAboveTheApprovedPriceIsHeldAgain() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        await harness.provider.setPreliminary(.usd(1, isEstimate: true))
        await harness.provider.setQuote(.failure(.network))
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        await harness.repository.wait(for: job.id, .paused(.agentLimit))
        await harness.provider.setQuote(.success(.usd(6, isEstimate: false)))
        try await engine.resume(job.id)
        await eventually {
            await harness.repository.snapshotJobs().first { $0.id == job.id }?.agent?.hold == .aboveApprovedPrice
        }
        #expect(harness.log.count("submit") == 0)

        try await engine.resume(job.id)
        await harness.repository.wait(for: job.id, .done)
        #expect(harness.log.count("submit") == 1)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents).spent == 600)
    }

    @Test func theLedgerFailingPausesWithoutSending() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine(agentPolicy: policy(BrokenLedger()))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))

        #expect(paused.agent?.hold == .ledgerUnavailable)
        #expect(harness.log.count("submit") == 0)
    }

    @Test func withoutALedgerNothingAnAgentAsksForIsSent() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))

        #expect(paused.agent?.hold == .ledgerUnavailable)
        #expect(harness.log.count("submit") == 0)
    }

    /// The person's own cap holds for agents too, and is checked strictly at the price about to be sent.
    @Test func thePersonsDailyCapStillApplies() async throws {
        var harness = Harness()
        harness.spendStatus = SpendStatus(committedToday: 0, cap: .usd(1))
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))

        await #expect(throws: JobEngineError.self) {
            try await engine.enqueue(makeSpec(), overCapApproved: true, agent: origin())
        }
        #expect(harness.log.count("submit") == 0)
    }

    /// Spend that grew after the job was queued still stops it at submit, before the agent's own limits.
    @Test func thePersonsCapIsCheckedAgainRightBeforeTheSubmit() async throws {
        let harness = Harness()
        let reads = CallLog()
        let engine = try await harness.makeEngine(
            readSpend: { _ in
                reads.append("read")
                return SpendStatus(committedToday: reads.count("read") > 1 ? 1.5 : 0, cap: .usd(2))
            }, agentPolicy: policy(ledger(harness)))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        await harness.repository.wait(for: job.id, .paused(.priceAboveCap))

        #expect(harness.log.count("submit") == 0)
    }

    @Test func aRefusedSubmitGivesItsReservationBack() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        await harness.provider.script(submit: [.fail(.validation(field: nil, message: "bad prompt"))])
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let failed = try #require(await harness.repository.wait(for: job.id, .failed(reason: .message("bad prompt"))))

        #expect(failed.agent?.reservation == nil)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal())
    }

    /// A lost answer may have been charged: the reservation stays, and the resend with the same key reserves nothing
    /// more.
    @Test func aLostAnswerKeepsItsReservationAndTheResendReservesNoMore() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        await harness.provider.script(submit: [.fail(.network)])
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        await harness.repository.wait(for: job.id, .done)

        #expect(harness.log.count("submit") == 2)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal(spent: 130))
    }

    /// Cut off while the submit waits for its answer (quit, cancel): it may have reached Higgsfield, so the
    /// reservation stays.
    @Test func aSubmitCutOffKeepsItsReservation() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        await harness.provider.script(submit: [.hang])
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        _ = try await engine.enqueue(makeSpec(), agent: origin())
        await eventually { harness.log.count("submit") == 1 }
        await engine.stop()

        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal(reserved: 130))
    }

    /// A submit cut off without an idempotency key may have been charged: the retry, a new attempt, reserves anew,
    /// and the old reservation keeps counting, through the next launch too.
    @Test func aRetryKeepsTheChargeOfASubmitThatMayHaveBeenSent() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.hang])
        let first = try await harness.makeEngine(agentPolicy: policy(ledger))
        let job = try await first.enqueue(makeSpec(), agent: origin())
        await eventually { harness.log.count("submit") == 1 }
        await first.stop()

        let second = try await harness.makeEngine(agentPolicy: policy(ledger))
        await harness.repository.wait(for: job.id, .failed(reason: .submitCutOff))
        try await second.retry(job.id)
        await harness.repository.wait(for: job.id, .done)
        await second.stop()
        _ = try await harness.makeEngine(agentPolicy: policy(ledger))

        #expect(harness.log.count("submit") == 2)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal(spent: 260))
    }

    /// A submit without an idempotency key that may have been taken is sent again as a new submit: its reservation
    /// keeps counting next to the new one's, through the next launch too.
    @Test func aNewSubmitKeepsTheChargeOfTheOneBefore() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.fail(.network)])
        let first = try await harness.makeEngine(agentPolicy: policy(ledger))
        let job = try await first.enqueue(makeSpec(), agent: origin())
        await harness.repository.wait(for: job.id, .done)
        await first.stop()
        _ = try await harness.makeEngine(agentPolicy: policy(ledger))

        #expect(harness.log.count("submit") == 2)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal(spent: 260))
    }

    @Test func variantsKeepTheAgentButNotTheReservation() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))
        var spec = makeSpec()
        spec.variants = 2

        let job = try await engine.enqueue(spec, agent: origin(maxCents: 300))
        await harness.repository.wait { snapshot in
            snapshot.jobs.values.filter { $0.batchID == job.batchID && $0.state == .done }.count == 2
        }

        let jobs = await harness.repository.snapshotJobs().filter { $0.batchID == job.batchID }
        #expect(jobs.allSatisfy { $0.agent?.requestID == "r-1" })
        #expect(jobs.filter { $0.agent?.reservation != nil }.count == 1)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents).spent == 260)
    }

    /// A job the plan's unlimited allowance would pay for waits for the person while agents may not use it, even with
    /// room in the budget; their Confirm sends it, and it counts nothing.
    @Test func anUnlimitedJobWaitsForThePersonWhileAgentsMayNotUseUnlimited() async throws {
        let harness = Harness()
        await harness.provider.payUnlimited(true)
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))
        #expect(paused.agent?.hold == .unlimitedNotAllowed)
        #expect(harness.log.count("submit") == 0)

        try await engine.resume(job.id)
        await harness.repository.wait(for: job.id, .done)
        #expect(harness.log.count("submit") == 1)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal())
    }

    /// Allowed, it runs with no budget at all and counts nothing against it.
    @Test func anUnlimitedJobRunsWithoutTheBudgetWhenAgentsMayUseUnlimited() async throws {
        let harness = Harness()
        await harness.provider.payUnlimited(true)
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger, limit: 0, unlimited: true))

        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 0))
        await harness.repository.wait(for: job.id, .done)

        #expect(harness.log.count("submit") == 1)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal())
    }

    /// The allowance didn't pay for a job sent for it: what it was charged counts, and for the rest of the day agents'
    /// jobs for the allowance keep every limit, so with no budget the next one waits for the person.
    @Test func anUnlimitedJobChargedAnywayCountsAndEndsUnlimitedForTheDay() async throws {
        let harness = Harness()
        await harness.provider.payUnlimited(true, answer: (paid: false, charged: .usd(2, isEstimate: false)))
        let ledger = ledger(harness)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger, limit: 0, unlimited: true))

        let first = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 0))
        await harness.repository.wait(for: first.id, .done)
        #expect(
            try await ledger.total(on: harness.clock.now, unit: .usdCents)
                == AgentSpendTotal(spent: 200, unlimitedCharged: true))

        let second = try await engine.enqueue(makeSpec(), agent: origin(request: "r-2"))
        let paused = try #require(await harness.repository.wait(for: second.id, .paused(.agentLimit)))
        #expect(paused.agent?.hold == .overDailyBudget)
        #expect(harness.log.count("submit") == 1)

        let tomorrow = AgentSpendFile(
            file: file, now: { [clock = harness.clock] in clock.now.addingTimeInterval(86_400) })
        #expect(
            try await !tomorrow.total(on: harness.clock.now.addingTimeInterval(86_400), unit: .usdCents)
                .unlimitedCharged)
    }

    /// The setting only covers the allowance: a job it doesn't pay for keeps every limit.
    @Test func lettingAgentsUseUnlimitedLeavesOtherJobsWithinTheBudget() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness), limit: 0, unlimited: true))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.agentLimit)))

        #expect(paused.agent?.hold == .overDailyBudget)
        #expect(harness.log.count("submit") == 0)
    }

    /// Higgsfield doesn't bill a generation that failed, was refused by moderation or was cancelled on its side: the
    /// job's reservation stops counting once the provider says so.
    @Test(arguments: [
        RemoteStatus.failed(message: nil), .failed(message: "Boom"), .rejected(.explicitContent), .canceled,
    ])
    func aJobThatEndedUnbilledCountsNothing(status: RemoteStatus) async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        await harness.provider.hold(status)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        await eventually { await harness.repository.snapshotJobs().first { $0.id == job.id }?.state.isTerminal == true }
        await eventually { (try? await ledger.total(on: harness.clock.now, unit: .usdCents)) == AgentSpendTotal() }

        #expect(harness.log.count("submit") == 1)
    }

    /// One variant of two failed: the submit counts the share of the one that was made.
    @Test func aFailedVariantGivesItsShareBack() async throws {
        let harness = Harness(statusBatchLimit: 4)
        let ledger = ledger(harness)
        await harness.provider.setBatch(statuses: ["r1-v1": .failed(message: nil)])
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))
        var spec = makeSpec()
        spec.variants = 2

        let job = try await engine.enqueue(spec, agent: origin(maxCents: 300))
        await harness.repository.wait { snapshot in
            snapshot.jobs.values.filter { $0.batchID == job.batchID && $0.state.isTerminal }.count == 2
        }

        await eventually { (try? await ledger.total(on: harness.clock.now, unit: .usdCents).spent) == 130 }
    }

    /// The person's cancel of a job still queued at Higgsfield: cancelled there, so never billed.
    @Test func aJobCanceledWhileQueuedCountsNothing() async throws {
        let harness = Harness()
        let ledger = ledger(harness)
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        await harness.repository.wait(for: job.id, .queued)
        try await engine.cancel(job.id)

        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal())
    }

    /// Past the deadline the generation may still finish and be charged: the reservation keeps counting.
    @Test func aJobPastTheDeadlineKeepsItsCharge() async throws {
        let harness = Harness(generationDeadline: 3600)
        let ledger = ledger(harness)
        await harness.provider.script(status: Array(repeating: .failure(.network), count: 500))
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger))

        let job = try await engine.enqueue(makeSpec(), agent: origin())
        let failed = try #require(await harness.repository.wait(for: job.id, .failed(reason: .deadline)))

        #expect(failed.mayHaveBeenCharged)
        #expect(try await ledger.total(on: harness.clock.now, unit: .usdCents) == AgentSpendTotal(spent: 130))
    }

    /// The agent's request ID names the job: queueing it again returns the same job.
    @Test func aKnownJobIDIsReturnedNotQueuedAgain() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))
        let id = UUID()

        let first = try await engine.enqueue(makeSpec(), id: id, agent: origin())
        let second = try await engine.enqueue(makeSpec(), id: id, agent: origin())
        await harness.repository.wait(for: id, .done)

        #expect(first.id == id && second.id == id)
        #expect(harness.log.count("submit") == 1)
    }

    @Test func retryForgetsThePersonsApproval() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.validation(field: nil, message: "no"))])
        let engine = try await harness.makeEngine(agentPolicy: policy(ledger(harness)))

        let job = try await engine.enqueue(makeSpec(), agent: origin(maxCents: 10))
        await harness.repository.wait(for: job.id, .paused(.agentLimit))
        try await engine.resume(job.id)
        await harness.repository.wait(for: job.id, .failed(reason: .message("no")))
        try await engine.retry(job.id)

        await eventually {
            await harness.repository.snapshotJobs().first { $0.id == job.id }?.state == .paused(.agentLimit)
        }
        let held = await harness.repository.snapshotJobs().first { $0.id == job.id }
        #expect(held?.agent?.approvedByPerson == false)
        #expect(harness.log.count("submit") == 1)
    }
}

@Suite struct AgentSpendFileTests {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("agent-spend-\(UUID().uuidString).json")
    let day = Date(timeIntervalSince1970: 1_791_892_800)

    func cents(_ amount: Int, at date: Date? = nil) -> AgentSpend {
        AgentSpend(jobID: UUID(), money: AgentMoney(amount, .usdCents), at: date ?? day)
    }

    @Test func reservingStopsAtTheLimitAndSurvivesARestart() async throws {
        let ledger = AgentSpendFile(file: file, now: { [day] in day })
        #expect(try await ledger.reserve(cents(60), dailyLimit: 100))
        #expect(try await !ledger.reserve(cents(41), dailyLimit: 100))
        #expect(try await ledger.reserve(cents(40), dailyLimit: 100))

        let reopened = AgentSpendFile(file: file, now: { [day] in day })
        #expect(try await reopened.total(on: day, unit: .usdCents) == AgentSpendTotal(reserved: 100))
        #expect(try await reopened.total(on: day, unit: .credits) == AgentSpendTotal())
    }

    /// Many submits at once can't all take the last of the budget.
    @Test func concurrentReservationsNeverPassTheLimit() async throws {
        let ledger = AgentSpendFile(file: file, now: { [day] in day })
        let granted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { (try? await ledger.reserve(cents(10), dailyLimit: 55)) ?? false } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(granted == 5)
    }

    @Test func settleReplacesAndReleaseOnlyGivesBackWhatIsUnsettled() async throws {
        let ledger = AgentSpendFile(file: file, now: { [day] in day })
        let charged = cents(100)
        let unsent = cents(30)
        _ = try await ledger.reserve(charged, dailyLimit: nil)
        _ = try await ledger.reserve(unsent, dailyLimit: nil)

        try await ledger.settle(charged.id, amount: 80)
        try await ledger.release(unsent.id)
        try await ledger.release(charged.id)

        #expect(try await ledger.total(on: day, unit: .usdCents) == AgentSpendTotal(spent: 80))
    }

    /// Parts that ended unbilled stop counting their share, each once, rounded up; settling after keeps that.
    @Test func unbilledPartsStopCountingTheirShare() async throws {
        let ledger = AgentSpendFile(file: file, now: { [day] in day })
        let spend = cents(10)
        _ = try await ledger.reserve(spend, dailyLimit: nil)

        try await ledger.unbill(spend.id, part: "a", of: 3)
        try await ledger.unbill(spend.id, part: "a", of: 3)
        #expect(try await ledger.total(on: day, unit: .usdCents) == AgentSpendTotal(reserved: 7))
        try await ledger.settle(spend.id, amount: nil)
        #expect(try await ledger.total(on: day, unit: .usdCents) == AgentSpendTotal(spent: 7))
        try await ledger.unbill(spend.id, part: "b", of: 3)
        try await ledger.unbill(spend.id, part: "c", of: 3)

        let reopened = AgentSpendFile(file: file, now: { [day] in day })
        #expect(try await reopened.total(on: day, unit: .usdCents) == AgentSpendTotal())
        try await reopened.unbill(UUID(), part: "x", of: 1)
    }

    @Test func anUnreadableFileThrowsRatherThanCountingFromZero() async throws {
        try Data("not json".utf8).write(to: file)
        let ledger = AgentSpendFile(file: file, now: { [day] in day })

        await #expect(throws: (any Error).self) { try await ledger.total(on: day, unit: .usdCents) }
        await #expect(throws: (any Error).self) { try await ledger.reserve(cents(1), dailyLimit: nil) }
    }

    @Test func oldDaysAreDroppedAndDoNotCount() async throws {
        let ledger = AgentSpendFile(file: file, now: { [day] in day })
        let lastWeek = day.addingTimeInterval(-7 * 86_400)
        _ = try await ledger.reserve(cents(500, at: lastWeek), dailyLimit: nil)
        _ = try await ledger.reserve(cents(5), dailyLimit: nil)

        #expect(try await ledger.total(on: day, unit: .usdCents) == AgentSpendTotal(reserved: 5))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [Any]
        #expect(saved?.count == 1)
    }
}
