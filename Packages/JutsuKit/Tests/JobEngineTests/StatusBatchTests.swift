import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

/// Polling a connection that reads several statuses in one call, as the account's `jobs_wait` does.
@Suite(.timeLimit(.minutes(1)))
struct StatusBatchTests {
    private func enqueue(_ count: Int, on engine: JobEngine, harness: Harness) async throws -> [Job] {
        var jobs: [Job] = []
        for _ in 0..<count {
            jobs.append(try await engine.enqueue(makeSpec()))
            harness.clock.advance(by: 1)
        }
        return jobs
    }

    @Test func groupsHoldAtMostTheLimit() {
        #expect(StatusBatch.groups(Array(0..<26), of: 12) == [Array(0..<12), Array(12..<24), [24, 25]])
        #expect(StatusBatch.groups(Array(0..<12), of: 12) == [Array(0..<12)])
        #expect(StatusBatch.groups([Int](), of: 12).isEmpty)
        #expect(StatusBatch.groups([1, 2], of: 0) == [[1], [2]])
    }

    @Test func sixProcessingJobsShareOneStatusCallPerTick() async throws {
        let harness = Harness(maxConcurrency: 6, statusBatchLimit: 12)
        await harness.provider.hold(.inProgress)
        let engine = try await harness.makeEngine()
        let jobs = try await enqueue(6, on: engine, harness: harness)
        await harness.repository.wait { $0.count(in: .processing) == 6 }
        let requestIDs = Set((1...6).map { "r\($0)" })
        await eventually { await harness.provider.batches.contains { Set($0) == requestIDs } }

        await harness.provider.hold(nil)
        for job in jobs { await harness.repository.wait(for: job.id, .done) }
        #expect(await harness.provider.statusCalls == 0)
        let batches = await harness.provider.batches
        #expect(batches.allSatisfy { !$0.isEmpty && $0.count <= 12 && Set($0).count == $0.count })
        // One call per tick: each call waits out a tick of its own.
        #expect(batches.count <= harness.clock.sleeps.count)
    }

    @Test func moreThanTwelveJobsAreSplitIntoGroups() async throws {
        let harness = Harness(maxConcurrency: 14, statusBatchLimit: 12)
        await harness.provider.hold(.inProgress)
        let engine = try await harness.makeEngine()
        _ = try await enqueue(14, on: engine, harness: harness)
        await harness.repository.wait { $0.count(in: .processing) == 14 }

        let all = Set((1...14).map { "r\($0)" })
        await eventually {
            let batches = await harness.provider.batches
            return zip(batches, batches.dropFirst()).contains { $0.count == 12 && Set($0 + $1) == all }
        }
        #expect(await harness.provider.batches.allSatisfy { $0.count <= 12 })
        #expect(await harness.provider.statusCalls == 0)
    }

    @Test func eachJobGetsItsOwnStatusFromTheSharedAnswer() async throws {
        let harness = Harness(maxConcurrency: 3, statusBatchLimit: 12)
        await harness.provider.setBatch(statuses: [
            "r2": .failed(message: "Bad input"), "r3": .rejected(.explicitContent),
        ])
        let engine = try await harness.makeEngine()
        let jobs = try await enqueue(3, on: engine, harness: harness)

        await harness.repository.wait { snapshot in
            jobs.allSatisfy { snapshot.jobs[$0.id]?.state.isActive == false }
        }
        var states: [String: JobState] = [:]
        for job in jobs {
            let stored = try #require(await harness.repository.job(id: job.id))
            states[try #require(stored.remote?.requestID)] = stored.state
        }
        #expect(states["r1"] == .done)
        #expect(states["r2"] == .failed(reason: .message("Bad input")))
        #expect(states["r3"] == .rejected)
        #expect(await harness.provider.statusCalls == 0)
    }

    @Test(arguments: [(7.0, 7.0), (0, 1), (3600, 30)])
    func theWaitTheProviderAsksForIsKeptWithinBounds(asked: TimeInterval, slept: TimeInterval) async throws {
        let harness = Harness(statusBatchLimit: 12)
        await harness.provider.hold(.inProgress)
        await harness.provider.setBatch(pollAfter: asked)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.batches.count >= 3 }

        #expect(harness.clock.sleeps.contains(slept))
        if asked != slept { #expect(!harness.clock.sleeps.contains(asked)) }
        await harness.provider.hold(nil)
        await harness.repository.wait(for: job.id, .done)
    }

    @Test(arguments: [
        FakeProvider.BatchMode.unavailable, .fail(.network), .fail(.validation(field: nil, message: "x")),
    ])
    func withoutASharedAnswerEachJobAsksAlone(mode: FakeProvider.BatchMode) async throws {
        let harness = Harness(maxConcurrency: 2, statusBatchLimit: 12)
        await harness.provider.setBatch(mode)
        await harness.provider.hold(.inProgress)
        let engine = try await harness.makeEngine()
        let jobs = try await enqueue(2, on: engine, harness: harness)
        await harness.repository.wait { $0.count(in: .processing) == 2 }
        await eventually { await harness.provider.statusCalls >= 4 }

        await harness.provider.hold(nil)
        for job in jobs { await harness.repository.wait(for: job.id, .done) }
        #expect(await !harness.provider.batches.isEmpty)
    }

    @Test func aJobMissingFromTheAnswerAsksAlone() async throws {
        let harness = Harness(maxConcurrency: 2, statusBatchLimit: 12)
        await harness.provider.setBatch(omitting: ["r1"])
        await harness.provider.hold(.inProgress)
        let engine = try await harness.makeEngine()
        let jobs = try await enqueue(2, on: engine, harness: harness)
        await harness.repository.wait { $0.count(in: .processing) == 2 }
        await eventually { await harness.provider.statusCalls >= 2 }

        await harness.provider.hold(nil)
        for job in jobs { await harness.repository.wait(for: job.id, .done) }
        #expect(await harness.provider.statusAsked.allSatisfy { $0 == "r1" })
    }

    @Test func cancelStopsAJobWaitingForTheSharedCall() async throws {
        let harness = Harness(statusBatchLimit: 12)
        let gate = Gate<Void>()
        await harness.provider.setBatch(.held(until: gate))
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await gate.isWaiting }

        try await engine.cancel(job.id)

        #expect(await harness.repository.job(id: job.id)?.state == .canceled)
        #expect(await harness.provider.cancels == ["r1"])
        await gate.open(.success(()))
        await quiesce()
        #expect(await harness.repository.states(of: job.id).last == .canceled)
        #expect(await harness.provider.statusCalls == 0)
    }

    @Test func stopDoesNotWaitForTheSharedCall() async throws {
        let harness = Harness(statusBatchLimit: 12)
        let gate = Gate<Void>()
        await harness.provider.setBatch(.held(until: gate))
        await harness.provider.hold(.inProgress)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await gate.isWaiting }

        await engine.stop()

        #expect(await harness.repository.job(id: job.id)?.state == .queued)
        await gate.open(.success(()))
        await harness.provider.hold(nil)
        await harness.provider.setBatch()
        try await engine.start()
        await harness.repository.wait(for: job.id, .done)
    }

    @Test func anAPIKeyStillPollsEachJob() async throws {
        let harness = Harness(maxConcurrency: 2)
        await harness.provider.script(status: [.success(.inProgress), .success(.inProgress)])
        let engine = try await harness.makeEngine()
        let jobs = try await enqueue(2, on: engine, harness: harness)
        for job in jobs { await harness.repository.wait(for: job.id, .done) }
        #expect(await harness.provider.batches.isEmpty)
        #expect(await harness.provider.statusCalls == 4)
    }
}
