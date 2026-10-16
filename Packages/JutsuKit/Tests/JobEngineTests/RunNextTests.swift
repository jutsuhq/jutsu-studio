import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

@Suite(.timeLimit(.minutes(1)))
struct RunNextTests {
    /// Queues `count` jobs a minute apart and waits until the engine holds them all.
    private func enqueue(_ count: Int, on engine: JobEngine, harness: Harness) async throws -> [Job] {
        var jobs: [Job] = []
        for _ in 0..<count {
            jobs.append(try await engine.enqueue(makeSpec()))
            harness.clock.advance(by: 60)
        }
        return jobs
    }

    @Test func runNextOnTheLastOfFiveWaitingJobsSubmitsItNext() async throws {
        let harness = Harness(maxConcurrency: 2)
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let running = try await enqueue(2, on: engine, harness: harness)
        for job in running { await harness.repository.wait(for: job.id, .queued) }
        let waiting = try await enqueue(5, on: engine, harness: harness)
        await eventually { await engine.limiter.waiterCount == 5 }

        let last = try #require(waiting.last)
        try await engine.runNext(last.id)
        #expect(await harness.repository.job(id: last.id)?.promotedAt != nil)
        try await engine.cancel(running[0].id)

        await harness.repository.wait(for: last.id, .queued)
        #expect(await harness.provider.submitKeys.count == 3)
        #expect(await harness.provider.submitKeys.last == last.idempotencyKey)
        #expect(await engine.limiter.waitingIDs == waiting.dropLast().map(\.id))
    }

    @Test func waitingOrderAndPromotionSurviveARestart() async throws {
        let harness = Harness(maxConcurrency: 1)
        await harness.provider.hold(.queued)
        let first = try await harness.makeEngine()
        let running = try #require(try await enqueue(1, on: first, harness: harness).first)
        await harness.repository.wait(for: running.id, .queued)
        let waiting = try await enqueue(3, on: first, harness: harness)
        await eventually { await first.limiter.waiterCount == 3 }
        try await first.runNext(waiting[1].id)
        await first.stop()

        let second = try await harness.makeEngine()
        await eventually { await second.limiter.waiterCount == 3 }
        #expect(await second.limiter.waitingIDs == [waiting[1].id, waiting[0].id, waiting[2].id])

        try await second.cancel(running.id)
        await harness.repository.wait(for: waiting[1].id, .queued)
        #expect(await harness.provider.submitKeys.last == waiting[1].idempotencyKey)
    }

    @Test func runNextOnlyReordersJobsWaitingForASlot() async throws {
        let harness = Harness(maxConcurrency: 1)
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .queued)

        await #expect(throws: JobEngineError.notWaiting(.queued)) { try await engine.runNext(job.id) }
        #expect(await harness.repository.job(id: job.id)?.promotedAt == nil)
    }

    @Test func stageTimesAreRecordedAndARetryClearsThem() async throws {
        let harness = Harness()
        await harness.provider.script(status: [.success(.queued), .success(.inProgress), .success(.inProgress)])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())

        let done = try #require(await harness.repository.wait(for: job.id, .done))
        let submittedAt = try #require(done.submittedAt)
        let processingAt = try #require(done.processingAt)
        let chargedAt = try #require(done.chargedAt)
        #expect(job.createdAt <= submittedAt)
        #expect(processingAt > submittedAt)
        #expect(chargedAt > processingAt)
        #expect(done.queueWait == processingAt.timeIntervalSince(job.createdAt))
        #expect(done.processingTime == chargedAt.timeIntervalSince(processingAt))

        await harness.provider.script(status: [.success(.inProgress), .success(.failed(message: "boom"))])
        let again = try await engine.enqueue(makeSpec())
        let failed = try #require(await harness.repository.wait(for: again.id, .failed(reason: .message("boom"))))
        let firstSubmit = try #require(failed.submittedAt)
        #expect(failed.processingAt != nil)

        // The second attempt is never reported in progress.
        try await engine.retry(again.id)
        let retried = try #require(await harness.repository.wait(for: again.id, .done))
        #expect(try #require(retried.submittedAt) > firstSubmit)
        #expect(retried.processingAt == nil)
    }
}
