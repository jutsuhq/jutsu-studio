import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

@Suite(.timeLimit(.minutes(1)))
struct RetryTests {
    /// Every distinct retry the engine published for `id`, until the job reaches `state`.
    private func retries(of id: UUID, in engine: JobEngine, until state: JobState) async -> [RetryStatus] {
        var retries: [RetryStatus] = []
        for await event in engine.events where event.id == id {
            if let retrying = event.retrying, retries.last != retrying { retries.append(retrying) }
            if event.state == state { break }
        }
        return retries
    }

    @Test func aRetryShowsOnTheJobUntilTheStepGetsThrough() async throws {
        let harness = Harness()
        await harness.provider.failUploads([.network, .server(status: 503)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let retries = await retries(of: job.id, in: engine, until: .done)

        #expect(retries.map(\.failures) == [1, 2])
        #expect(retries.map(\.cause) == [.network, .server(status: 503)])
        let since = try #require(retries.first?.since)
        #expect(retries.map(\.since) == [since, since])
        #expect(retries.map { $0.nextAttemptAt.timeIntervalSince(since) } == [5, 15])
        #expect(await harness.repository.job(id: job.id)?.retrying == nil)
    }

    @Test func aStepThatGetsThroughStartsTheCountAndTheBackoffAgain() async throws {
        let harness = Harness()
        await harness.provider.failUploads([.network, .network])
        await harness.provider.script(status: [.failure(.server(status: 502))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let retries = await retries(of: job.id, in: engine, until: .done)

        #expect(retries.map(\.failures) == [1, 2, 1])
        #expect(retries.map(\.cause) == [.network, .network, .server(status: 502)])
        let poll = try #require(retries.last)
        #expect(poll.nextAttemptAt.timeIntervalSince(poll.since) == 5)
    }

    @Test func aJobThatKeepsFailingBeforeSubmitPausesUntilResumed() async throws {
        let harness = Harness()
        await harness.provider.failUploads(Array(repeating: .modelUnavailable, count: 200))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.keptFailing)))

        let retrying = try #require(paused.retrying)
        #expect(retrying.cause == .modelUnavailable)
        #expect(retrying.failures >= 5)
        #expect(harness.clock.now.timeIntervalSince(retrying.since) >= 15 * 60)
        #expect(await harness.provider.submitKeys.isEmpty)
        let uploads = harness.log.count("upload")
        await quiesce()
        #expect(harness.log.count("upload") == uploads)

        await harness.provider.stopFailingUploads()
        try await engine.resume(job.id)
        let done = try #require(await harness.repository.wait(for: job.id, .done))
        #expect(done.retrying == nil)
    }

    @Test func aBusyAccountIsWaitedForPastThePauseBound() async throws {
        let harness = Harness()
        await harness.provider.script(submit: Array(repeating: .fail(.concurrencyLimit(max: nil)), count: 25))
        let engine = try await harness.makeEngine()
        let start = harness.clock.now

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .done)

        #expect(harness.clock.now.timeIntervalSince(start) > 15 * 60)
        #expect(await !harness.repository.states(of: job.id).contains(.paused(.keptFailing)))
    }

    @Test func aSubmittedJobWhosePollsKeepFailingIsNeverPausedAndFailsAtTheDeadline() async throws {
        let harness = Harness(generationDeadline: 3600)
        await harness.provider.script(status: Array(repeating: .failure(.network), count: 500))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let failed = try #require(
            await harness.repository.wait(for: job.id, .failed(reason: .deadline)))

        #expect(failed.timedOutAt != nil)
        #expect(failed.mayStillFinish)
        #expect(failed.retrying == nil)
        #expect(await harness.provider.submitKeys.count == 1)
        #expect(await !harness.repository.states(of: job.id).contains(.paused(.keptFailing)))
        #expect(await engine.limiter.inUse == 0)
    }

    @Test func aRestartForgetsTheRetriesOfTheRunBefore() async throws {
        let harness = Harness()
        await harness.provider.failUploads(Array(repeating: .network, count: 3))
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await harness.repository.wait { $0.jobs[job.id]?.retrying != nil }
        await first.stop()
        await harness.provider.stopFailingUploads()

        let second = try await harness.makeEngine()
        let done = try #require(await harness.repository.wait(for: job.id, .done))
        #expect(done.retrying == nil)
        await second.stop()
    }
}
