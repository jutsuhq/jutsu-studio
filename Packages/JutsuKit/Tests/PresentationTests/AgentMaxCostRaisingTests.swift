import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// What `create_video` sent again with a higher `max_cost` answers, by what the engine's check of its job said.
@MainActor
@Suite struct AgentMaxCostRaisingTests {
    struct Failed: Error {}

    func job(maxCents: Int, _ state: JobState = .paused(.agentLimit)) -> Job {
        var job = Job(
            spec: JobSpec(mode: .motionTransfer, source: nil, resolution: .p720), providerKind: .apiKey,
            cost: .usd(1.3, isEstimate: false))
        job.state = state
        job.agent = AgentOrigin(client: "claude-code", requestID: "r1", maxCost: AgentMoney(maxCents, .usdCents))
        return job
    }

    /// Answers for `ids` as the engine's check says `result`, with `current` as the job now; counts the raises and
    /// the record updates; `nil` for `result` is a job the engine doesn't have.
    func answer(
        _ ids: [UUID], to maxCents: Int = 130, result: AgentMaxCostRaise?, current: Job?, raises: Box<Int> = Box(0),
        records: Box<Int> = Box(0), recordFails: Bool = false
    ) async -> AgentRaiseOutcome<AgentRaisedJob> {
        await AgentMaxCostRaising.answer(
            ids, maxCost: AgentMoney(maxCents, .usdCents),
            raise: { _, _ in
                raises.update { $0 += 1 }
                return result
            },
            job: { _ in current },
            recordRaise: {
                records.update { $0 += 1 }
                if recordFails { throw Failed() }
            })
    }

    @Test func aLiftedJobGoesOnAndTheRequestStandsForTheNewMaxCost() async {
        let lifted = job(maxCents: 130, .preparing)
        let records = Box(0)
        #expect(
            await answer([lifted.id], result: .lifted, current: lifted, records: records)
                == .answer(AgentRaisedJob(job: lifted)))
        #expect(records.value == 1)
    }

    /// The job goes on even when the request's record can't be updated: the same request sent again finds the job
    /// already raised and records it then (`aJobAlreadyRaisedToThisMaxCostAnswersAsKnown`).
    @Test func aRecordThatCantBeUpdatedStillAnswersWithTheLiftedJob() async {
        let lifted = job(maxCents: 130, .preparing)
        let records = Box(0)
        #expect(
            await answer([lifted.id], result: .lifted, current: lifted, records: records, recordFails: true)
                == .answer(AgentRaisedJob(job: lifted)))
        #expect(records.value == 1)
    }

    /// Only a request of one job can be raised: variants, or a record without jobs, are a conflict, unchecked.
    @Test func aRequestOfOtherThanOneJobIsNotLiftable() async {
        let raises = Box(0)
        let held = job(maxCents: 100)
        for ids in [[], [held.id, UUID()]] {
            #expect(await answer(ids, result: .lifted, current: held, raises: raises) == .notLiftable)
        }
        #expect(raises.value == 0)
    }

    /// Still held, the job comes back with why, and the request keeps its old max_cost.
    @Test func aJobStillHeldSaysWhy() async {
        let held = job(maxCents: 100)
        let records = Box(0)
        #expect(
            await answer([held.id], result: .held(.overDailyBudget), current: held, records: records)
                == .answer(AgentRaisedJob(job: held, note: AgentJobRules.stillHeldNote(.overDailyBudget))))
        #expect(
            await answer([held.id], result: .overCap, current: held, records: records)
                == .answer(AgentRaisedJob(job: held, note: AgentJobRules.stillHeldNote(nil))))
        #expect(records.value == 0)
    }

    /// A raise that lifted the job but couldn't record it, or one that finished while this request was on its way,
    /// leaves the job running at this max_cost: the same request again is known, and recorded now, not a conflict.
    @Test func aJobAlreadyRaisedToThisMaxCostAnswersAsKnown() async {
        let raised = job(maxCents: 130, .processing)
        let records = Box(0)
        #expect(
            await answer([raised.id], result: .notLiftable, current: raised, records: records)
                == .answer(AgentRaisedJob(job: raised)))
        #expect(records.value == 1)
    }

    /// A recorded job that isn't there any more is answered as never queued, as a known request's is.
    @Test func aJobThatIsGoneIsAnsweredAsNeverQueued() async {
        let held = job(maxCents: 100)
        #expect(await answer([held.id], result: nil, current: nil) == .gone)
        for result in [AgentMaxCostRaise.lifted, .notLiftable, .held(.overMaxCost)] {
            #expect(await answer([held.id], result: result, current: nil) == .gone)
        }
    }

    /// A store that can't be read says nothing about the job: the failure goes to the agent, and the request stays.
    @Test func aJobThatCantBeReadIsAFailureNotGone() async {
        let held = job(maxCents: 100)
        await #expect(throws: Failed.self) {
            try await AgentMaxCostRaising.answer(
                [held.id], maxCost: AgentMoney(130, .usdCents), raise: { _, _ throws(Failed) in .lifted },
                job: { _ throws(Failed) in throw Failed() }, recordRaise: {})
        }
    }

    @Test func aJobNotRaisedToThisMaxCostIsNotLiftable() async {
        let records = Box(0)
        for other in [job(maxCents: 129, .processing), job(maxCents: 200, .processing)] {
            #expect(await answer([other.id], result: .notLiftable, current: other, records: records) == .notLiftable)
        }
        var credits = job(maxCents: 130, .processing)
        credits.agent?.maxCost = AgentMoney(130, .credits)
        #expect(await answer([credits.id], result: .notLiftable, current: credits, records: records) == .notLiftable)
        #expect(records.value == 0)
    }
}
