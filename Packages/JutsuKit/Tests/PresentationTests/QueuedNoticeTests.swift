import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct QueuedNoticeTests {
    private static func job(isDraft: Bool, cost: Cost, parentID: UUID? = nil) -> Job {
        var job = JobFixture.job(.waitingForSlot, cost: cost)
        job.spec.isDraft = isDraft
        job.parentID = parentID
        return job
    }

    @Test func oneJobSaysWhatItIsAndItsPrice() throws {
        try CostText.$locale.withValue(.enUS) {
            let final = try #require(QueuedNotice([Self.job(isDraft: false, cost: .usd(0.68, isEstimate: true))]))
            #expect(final.text == "Final queued · ~$0.68")
            let draft = try #require(QueuedNotice([Self.job(isDraft: true, cost: .credits(16, isEstimate: false))]))
            #expect(draft.text == "Draft queued · 16 cr")
        }
    }

    @Test func aBatchCountsItsJobsAndAddsTheirPrices() throws {
        try CostText.$locale.withValue(.enUS) {
            let jobs = [0.5, 0.25, 0.25].map { Self.job(isDraft: true, cost: .usd(Decimal($0), isEstimate: false)) }
            let notice = try #require(QueuedNotice(jobs))
            #expect(notice.text == "3 jobs queued · $1.00")
        }
    }

    @Test func pricesInDifferentUnitsLeaveThePriceOut() throws {
        let jobs = [
            Self.job(isDraft: true, cost: .usd(1, isEstimate: false)),
            Self.job(isDraft: true, cost: .credits(4, isEstimate: false)),
        ]
        #expect(try #require(QueuedNotice(jobs)).text == "2 jobs queued")
    }

    @Test func nothingQueuedHasNoNotice() {
        #expect(QueuedNotice([]) == nil)
    }

    @MainActor @Test func activeJobFindsTheQueuedFinalUntilItFinishes() {
        let parentID = UUID()
        var final = Self.job(isDraft: false, cost: .usd(1, isEstimate: false), parentID: parentID)
        let other = Self.job(isDraft: false, cost: .usd(1, isEstimate: false))
        let live = LiveJobs([final, other])
        #expect(live.activeJob(parentID: parentID, spec: final.spec)?.id == final.id)

        var otherResolution = final.spec
        otherResolution.resolution = .p1080
        #expect(live.activeJob(parentID: parentID, spec: otherResolution) == nil)

        final.state = .done
        live.apply(final)
        #expect(live.activeJob(parentID: parentID, spec: final.spec) == nil)
    }
}
