import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

@Suite(.timeLimit(.minutes(1)))
struct ProgressCoalescingTests {
    @Test func aFloodOfSmallStepsYieldsOnlyAFewEvents() async throws {
        let flood = (1...1_000).map { 0.5 + Double($0) * 0.000_005 }
        let harness = Harness(progressSteps: [0.5] + flood + [1])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())

        #expect(
            await preparingEvents(of: job.id, from: engine) == [
                "preparing 0.0", "preparing 0.5", "preparing 1.0", "uploading 0.0",
            ])
    }

    @Test func startAndEndAreAlwaysDelivered() async throws {
        let harness = Harness(progressSteps: [0.3, 0, 0.000_1, 0.999_9, 1, 1])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())

        #expect(
            await preparingEvents(of: job.id, from: engine) == [
                "preparing 0.0", "preparing 0.3", "preparing 0.0", "preparing 0.9999", "preparing 1.0",
                "preparing 1.0", "uploading 0.0",
            ])
    }

    @Test func smallStepsArePublishedOnceTheIntervalHasPassed() async throws {
        let harness = Harness()
        let (engine, ids) = try await pausedEngine(harness, jobs: 1)
        let id = ids[0]
        var events = engine.events.makeAsyncIterator()

        await engine.report(progress: 0.5, of: id, in: Self.paused)
        await engine.report(progress: 0.501, of: id, in: Self.paused)
        harness.clock.advance(by: 0.3)
        await engine.report(progress: 0.502, of: id, in: Self.paused)

        #expect(await events.next()?.progress == 0.5)
        #expect(await events.next()?.progress == 0.502)
    }

    @Test func aChangeAfterCoalescedProgressIsDeliveredAtOnceWithTheLatestProgress() async throws {
        let harness = Harness()
        let (engine, ids) = try await pausedEngine(harness, jobs: 1)
        let id = ids[0]
        var events = engine.events.makeAsyncIterator()

        await engine.report(progress: 0.5, of: id, in: Self.paused)
        await engine.report(progress: 0.504, of: id, in: Self.paused)
        try await engine.save(id) { @Sendable in $0.submitAttempt = SubmitAttempt(isIdempotent: true) }
        await engine.report(progress: 0.505, of: id, in: Self.paused)
        try await engine.apply(.resume, to: id) { @Sendable _ in }

        let first = try #require(await events.next())
        let saved = try #require(await events.next())
        let resumed = try #require(await events.next())
        #expect(first.progress == 0.5)
        #expect(saved.progress == 0.504)
        #expect(saved.submitAttempt != nil)
        #expect(resumed.state == .preparing)
        #expect(resumed.progress == 0)
    }

    @Test func oneJobsProgressNeverSuppressesAnothersEvents() async throws {
        let harness = Harness()
        let (engine, ids) = try await pausedEngine(harness, jobs: 2)
        let (a, b) = (ids[0], ids[1])
        var events = engine.events.makeAsyncIterator()

        await engine.report(progress: 0.5, of: a, in: Self.paused)
        await engine.report(progress: 0.5, of: b, in: Self.paused)
        await engine.report(progress: 0.502, of: a, in: Self.paused)
        await engine.report(progress: 0.502, of: b, in: Self.paused)
        await engine.report(progress: 0.6, of: b, in: Self.paused)
        try await engine.save(a) { @Sendable _ in }

        var seen: [String] = []
        for _ in 0..<4 {
            let event = try #require(await events.next())
            seen.append("\(event.id == a ? "a" : "b") \(event.progress)")
        }
        #expect(seen == ["a 0.5", "b 0.5", "b 0.6", "a 0.502"])
    }

    private static let paused = JobState.paused(.insufficientFunds)

    /// An engine holding paused jobs, which no runner touches, so the test alone reports their progress.
    private func pausedEngine(_ harness: Harness, jobs count: Int) async throws -> (JobEngine, [UUID]) {
        var ids: [UUID] = []
        for _ in 0..<count {
            var job = Job(
                spec: makeSpec(), providerKind: harness.provider.kind, owner: harness.provider.owner,
                cost: .usd(1.3, isEstimate: false), createdAt: harness.clock.now)
            job.state = Self.paused
            await harness.repository.save(job)
            ids.append(job.id)
        }
        return (try await harness.makeEngine(), ids)
    }

    private func preparingEvents(of id: UUID, from engine: JobEngine) async -> [String] {
        var seen: [String] = []
        for await event in engine.events where event.id == id {
            seen.append("\(event.state) \(event.progress)")
            if event.state != .preparing { break }
        }
        return seen
    }
}
