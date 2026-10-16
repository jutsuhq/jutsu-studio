import Foundation
import JutsuCore
import Testing

@testable import Presentation

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QueueProblemsTests {
    private let never = QueueProblems(clearedAt: 0, removed: "")

    @Test func aFailedJobStaysReachableAfterManyNewerResults() {
        let failed = JobFixture.job(
            .failed(reason: .message("Timed out")), createdMinutesAgo: 60, finishedMinutesAgo: 50)
        let done = (0..<20).map { JobFixture.job(.done, createdMinutesAgo: 40, finishedMinutesAgo: Double($0)) }
        let live = LiveJobs(done)
        // Not in memory at all, as after a relaunch with more than `storedFinishedLimit` newer results.
        #expect(live.job(failed.id) == nil)

        #expect(live.problemEntries(stored: [failed], problems: never).map(\.id) == [failed.id])
        #expect(live.recentFinishedEntries(limit: 8).count == 8)
        #expect(live.recentFinishedEntries(limit: .max).allSatisfy { $0.id != failed.id })
    }

    @Test func listsFailedRejectedAndCanceledNewestFirst() {
        let failed = JobFixture.job(.failed(reason: .message("x")), finishedMinutesAgo: 3)
        let rejected = JobFixture.job(.rejected, finishedMinutesAgo: 1)
        let canceled = JobFixture.job(.canceled, finishedMinutesAgo: 2)
        let done = JobFixture.job(.done, finishedMinutesAgo: 0)
        let running = JobFixture.job(.processing)
        let live = LiveJobs([done, running, canceled])

        let entries = live.problemEntries(stored: [failed, rejected, done], problems: never)
        #expect(entries.map(\.id) == [rejected.id, canceled.id, failed.id])
        #expect(live.recentFinishedEntries(limit: 8).map(\.id) == [done.id])
    }

    @Test func aRetriedJobLeavesTheSectionAtOnce() {
        var job = JobFixture.job(.failed(reason: .message("x")), finishedMinutesAgo: 3)
        let live = LiveJobs()
        let stored = job
        job.state = .preparing
        job.finishedAt = nil
        live.apply(job)

        #expect(live.problemEntries(stored: [stored], problems: never).isEmpty)
    }

    @Test func aBatchStillRunningKeepsItsFailedJobInActive() {
        let batch = UUID()
        var failed = JobFixture.job(.failed(reason: .message("x")), finishedMinutesAgo: 1)
        failed.batchID = batch
        var running = JobFixture.job(.processing)
        running.batchID = batch
        let live = LiveJobs([failed, running])

        #expect(live.problemEntries(stored: [failed], problems: never).isEmpty)
        #expect(live.activeEntries.map(\.id) == [batch])
    }

    @Test func removeAndClearAllHideJobs() {
        let older = JobFixture.job(.failed(reason: .message("x")), finishedMinutesAgo: 30)
        let newer = JobFixture.job(.canceled, finishedMinutesAgo: 10)
        let live = LiveJobs()
        var problems = never

        problems.remove(newer.id, loaded: [older.id, newer.id])
        #expect(live.problemEntries(stored: [older, newer], problems: problems).map(\.id) == [older.id])

        problems.clearAll(now: JobFixture.now.addingTimeInterval(-20 * 60))
        #expect(problems.removed.isEmpty)
        #expect(live.problemEntries(stored: [older, newer], problems: problems).map(\.id) == [newer.id])

        let later = JobFixture.job(.failed(reason: .message("y")), finishedMinutesAgo: 1)
        live.apply(later)
        // Failed after "Clear all", so it shows again.
        #expect(live.problemEntries(stored: [older, newer], problems: problems).map(\.id) == [later.id, newer.id])
    }

    @Test func removingForgetsIDsTheStoreNoLongerReturns() {
        let gone = UUID()
        let kept = UUID()
        let new = UUID()
        var problems = QueueProblems(clearedAt: 0, removed: "\(gone.uuidString),\(kept.uuidString)")
        problems.remove(new, loaded: [kept, new])
        #expect(problems.removed == [kept, new])
    }

    @Test func roundTripsThroughItsStoredValues() {
        let ids = [UUID(), UUID()]
        var problems = QueueProblems(clearedAt: 0, removed: "")
        #expect(problems.clearedAt == nil)
        #expect(problems.storedClearedAt == 0)
        problems.clearAll(now: JobFixture.now)
        problems.remove(ids[0], loaded: ids)
        problems.remove(ids[1], loaded: ids)

        let restored = QueueProblems(clearedAt: problems.storedClearedAt, removed: problems.storedRemoved)
        #expect(restored == problems)
        #expect(QueueProblems(clearedAt: 0, removed: "not-an-id,,").removed.isEmpty)
    }
}
