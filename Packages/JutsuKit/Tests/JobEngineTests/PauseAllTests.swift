import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

@Suite(.timeLimit(.minutes(1)))
struct PauseAllTests {
    @Test func pauseAllSubmitsNothingNewUntilResumeAllWhileSubmittedJobsFinish() async throws {
        let harness = Harness(maxConcurrency: 1)
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let running = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: running.id, .queued)
        var waiting: [UUID] = []
        for _ in 0..<5 { waiting.append(try await engine.enqueue(makeSpec()).id) }
        await harness.repository.wait { $0.count(in: .waitingForSlot) == 5 }

        await engine.pauseAll()
        for id in waiting { #expect(await harness.repository.job(id: id)?.state == .paused(.byUser)) }

        await harness.provider.hold(nil)
        await harness.repository.wait(for: running.id, .done)
        // `.done` is saved after the slot is released, so no settle is needed.
        #expect(await harness.provider.acceptedCount == 1)
        #expect(await engine.limiter.inUse == 0)
        for id in waiting { #expect(await harness.repository.job(id: id)?.state == .paused(.byUser)) }

        await engine.resumeAll()
        for id in waiting { await harness.repository.wait(for: id, .done) }
        #expect(await harness.provider.acceptedCount == 6)
        #expect(await harness.provider.maxInFlight == 1)
    }

    @Test func pauseByUserSurvivesARestartAndAConnectionChange() async throws {
        let harness = Harness(online: false)
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .uploading)

        await first.pauseAll()
        await first.setProvider(harness.provider)
        #expect(await harness.repository.job(id: job.id)?.state == .paused(.byUser))
        await first.stop()

        harness.connectivity.set(online: true)
        let second = try await harness.makeEngine()
        await second.setProvider(harness.provider)
        await quiesce()
        #expect(await harness.repository.job(id: job.id)?.state == .paused(.byUser))
        #expect(await harness.provider.uploads.isEmpty)

        await second.resumeAll()
        await harness.repository.wait(for: job.id, .done)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
    }

    @Test func pauseAllTakesOverAConnectionPauseAndResumeAllKeepsItsCause() async throws {
        let harness = Harness(online: false)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .uploading)
        let other = FakeProvider(kind: .account, log: CallLog())
        await engine.setProvider(other)
        #expect(await harness.repository.job(id: job.id)?.state == .paused(.connectionNeedsAttention))

        await engine.pauseAll()
        harness.connectivity.set(online: true)
        await engine.setProvider(harness.provider)
        await quiesce()
        #expect(await harness.repository.job(id: job.id)?.state == .paused(.byUser))

        await engine.setProvider(other)
        await engine.resumeAll()
        await harness.repository.wait {
            $0.history[job.id]?.filter { $0 == .paused(.connectionNeedsAttention) }.count == 2
        }
        await engine.setProvider(harness.provider)
        await harness.repository.wait(for: job.id, .done)
    }

    @Test func fundsPausesStayThroughPauseAllAndResumeAll() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.insufficientFunds)])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .paused(.insufficientFunds))

        await engine.pauseAll()
        await engine.resumeAll()
        await quiesce()
        #expect(await harness.repository.job(id: job.id)?.state == .paused(.insufficientFunds))
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
    }

    @Test func aSubmitAlreadySentIsNotPaused() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.hang])
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }

        await first.pauseAll()
        #expect(await harness.repository.job(id: job.id)?.state == .waitingForSlot)
        await first.stop()

        _ = try await harness.makeEngine()
        await harness.repository.wait(for: job.id, .done)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
        #expect(await harness.provider.acceptedCount == 1)
    }
}
