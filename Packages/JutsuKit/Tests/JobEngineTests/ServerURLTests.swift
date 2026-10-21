import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

/// Reused inputs as a tampered history entry would give them: the source video names a local file.
private func specReusingALocalFile() -> JobSpec {
    let local = URL(fileURLWithPath: "/home/me/Movies/private.mov")
    let image = RemoteAsset(url: URL(string: "https://cdn.example/a.png")!, id: "media-a")
    let reused = RemoteInputs(video: RemoteAsset(url: local, id: "media-v"), images: [image])
    let source = SourceClip(fileURL: local, duration: 8, pixelSize: PixelSize(width: 1080, height: 1920), range: 0...8)
    return JobSpec(
        mode: .objectSwap, source: source, references: [LocalImage(fileURL: image.url)], resolution: .p720,
        remoteInputs: reused)
}

@Suite(.timeLimit(.minutes(1)))
struct ServerURLEngineTests {
    static let deadline = EngineSettings(outputDirectory: URL(fileURLWithPath: "/tmp")).generationDeadline

    @Test func theDefaultDeadlineIsTwoHours() {
        #expect(Self.deadline == 2 * 3600)
    }

    @Test func reusedInputsThatAreLocalFilesFailTheJob() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(specReusingALocalFile())
        await harness.repository.wait(for: job.id, .failed(reason: .insecureInput))

        #expect(await harness.provider.submittedInputs.isEmpty)
        #expect(harness.log.count("prepareVideo") == 0)
        #expect(harness.log.count("download") == 0)
    }

    @Test func refusedReusedInputsAreNeverReadAsLocalFiles() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.validation(field: nil, message: "Media not found"))])
        var stored = Job(
            spec: specReusingALocalFile(), providerKind: .apiKey, owner: "key-a", cost: .usd(1.3, isEstimate: false))
        stored.state = .waitingForSlot
        await harness.repository.save(stored)

        _ = try await harness.makeEngine()
        let failed = await harness.repository.wait(for: stored.id, .failed(reason: .insecureInput))

        #expect(failed?.spec.remoteInputs != nil)
        #expect(harness.log.count("prepareVideo") == 0)
        #expect(harness.log.count("download") == 0)
        #expect(harness.log.count("upload") == 0)
    }

    @Test func aJobTheProviderNeverFinishesFailsAtTheDeadline() async throws {
        let harness = Harness(maxConcurrency: 1, generationDeadline: Self.deadline)
        await harness.provider.hold(.inProgress)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let failed = try #require(await harness.repository.wait(for: job.id, .failed(reason: .deadline)))

        let submittedAt = try #require(failed.submittedAt)
        #expect(harness.clock.now.timeIntervalSince(submittedAt) >= Self.deadline)
        #expect(await harness.provider.submitKeys.count == 1)
        #expect(await engine.limiter.inUse == 0)

        await harness.provider.hold(nil)
        let next = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: next.id, .done)
        #expect(await harness.repository.job(id: job.id)?.state == .failed(reason: .deadline))
        #expect(await harness.provider.submitKeys.count == 2)
    }

    @Test func aJobStillQueuedAtTheDeadlineFailsAfterPollingThroughIt() async throws {
        let harness = Harness(generationDeadline: Self.deadline)
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .failed(reason: .deadline))

        #expect(await harness.provider.statusCalls > 100)
    }

    /// Fails `job` at the deadline while the provider keeps generating it.
    private func timeOut(_ harness: Harness) async throws -> (JobEngine, Job) {
        await harness.provider.hold(.inProgress)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        let failed = try #require(await harness.repository.wait(for: job.id, .failed(reason: .deadline)))
        #expect(failed.mayStillFinish)
        return (engine, failed)
    }

    @Test func checkAgainAfterTheDeadlineFetchesTheResultWithoutSubmittingAgain() async throws {
        let harness = Harness(generationDeadline: Self.deadline)
        let (engine, failed) = try await timeOut(harness)

        await harness.provider.hold(nil)
        try await engine.checkAgain(failed.id)
        let done = try #require(await harness.repository.wait(for: failed.id, .done))

        #expect(await harness.provider.submitKeys.count == 1)
        #expect(done.remote == failed.remote)
        #expect(done.timedOutAt == nil)
    }

    @Test func retryAfterTheDeadlineChecksAgainInsteadOfSubmitting() async throws {
        let harness = Harness(generationDeadline: Self.deadline)
        let (engine, failed) = try await timeOut(harness)

        await harness.provider.hold(nil)
        try await engine.retry(failed.id)
        let done = try #require(await harness.repository.wait(for: failed.id, .done))

        #expect(await harness.provider.submitKeys == [failed.idempotencyKey])
        #expect(done.idempotencyKey == failed.idempotencyKey)
    }

    @Test func checkAgainStartsANewDeadline() async throws {
        let harness = Harness(generationDeadline: Self.deadline)
        let (engine, failed) = try await timeOut(harness)

        try await engine.checkAgain(failed.id)
        await harness.repository.wait { $0.history[failed.id]?.filter { $0 == failed.state }.count == 2 }

        let again = try #require(await harness.repository.job(id: failed.id))
        let checkedAgainAt = try #require(again.checkedAgainAt)
        let firstFailure = try #require(failed.finishedAt)
        #expect(checkedAgainAt >= firstFailure)
        #expect(harness.clock.now.timeIntervalSince(checkedAgainAt) >= Self.deadline)
        #expect(again.mayStillFinish)
        #expect(await harness.provider.submitKeys.count == 1)
    }

    @Test func onlyAJobPastItsDeadlineIsCheckedAgain() async throws {
        let harness = Harness()
        await harness.provider.script(status: [.success(.failed(message: "Server error"))])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .failed(reason: .message("Server error")))

        await #expect(throws: JobEngineError.notRetryable(.failed(reason: .message("Server error")))) {
            try await engine.checkAgain(job.id)
        }
    }
}
