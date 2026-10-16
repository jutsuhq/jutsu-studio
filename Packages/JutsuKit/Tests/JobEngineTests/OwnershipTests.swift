import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

func cacheKey(_ contentHash: String, owner: String? = "key-a") -> String {
    JobEngine.uploadCacheKey(contentHash, kind: .apiKey, owner: owner)
}

func storedJob(kind: ProviderKind = .apiKey, owner: String?, state: JobState = .preparing) -> Job {
    var job = Job(spec: makeSpec(), providerKind: kind, owner: owner, cost: .usd(1.3, isEstimate: false))
    job.state = state
    return job
}

@Suite(.timeLimit(.minutes(1)))
struct OwnershipTests {
    @Test func jobsBelongToTheConnectionThatQueuedThem() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())

        #expect(job.owner == "key-a")
        #expect(await harness.repository.wait(for: job.id, .done)?.owner == "key-a")
    }

    @Test func anotherAccountOfTheSameKindNeverRunsUnsubmittedJobs() async throws {
        let harness = Harness(online: false)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .uploading)

        let other = FakeProvider(owner: "key-b", log: CallLog())
        await engine.setProvider(other)
        #expect(await harness.repository.job(id: job.id)?.state == .paused(.connectionNeedsAttention))

        harness.connectivity.set(online: true)
        try await engine.resume(job.id)
        await harness.repository.wait {
            $0.history[job.id]?.filter { $0 == .paused(.connectionNeedsAttention) }.count == 2
        }
        #expect(await other.uploads.isEmpty)
        #expect(await other.submitKeys.isEmpty)

        await engine.setProvider(harness.provider)
        await harness.repository.wait(for: job.id, .done)
        #expect(await other.uploads.isEmpty)
    }

    @Test func submittedJobsAreNotPolledOrCanceledThroughAnotherAccount() async throws {
        let harness = Harness()
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .queued)

        let other = FakeProvider(owner: "key-b", log: CallLog())
        await engine.setProvider(other)
        await quiesce()
        await #expect(throws: JobEngineError.notConnected) { try await engine.cancel(job.id) }
        #expect(await other.statusCalls == 0)
        #expect(await other.cancels.isEmpty)
        #expect(await harness.repository.job(id: job.id)?.state == .queued)

        await harness.provider.hold(nil)
        await engine.setProvider(harness.provider)
        await harness.repository.wait(for: job.id, .done)
    }

    @Test func legacyJobsAdoptTheConnectionRestoredAtLaunch() async throws {
        let harness = Harness()
        let legacy = storedJob(owner: nil)
        await harness.repository.save(legacy)

        _ = try await harness.makeEngine()

        let done = try #require(await harness.repository.wait(for: legacy.id, .done))
        #expect(done.owner == "key-a")
    }

    @Test func legacyJobsOfAnotherKindAreNotAdopted() async throws {
        let harness = Harness()
        let legacy = storedJob(kind: .account, owner: nil)
        await harness.repository.save(legacy)

        _ = try await harness.makeEngine()

        let paused = try #require(await harness.repository.wait(for: legacy.id, .paused(.connectionNeedsAttention)))
        #expect(paused.owner == nil)
        #expect(await harness.provider.uploads.isEmpty)
    }

    @Test func uploadsAreReusedOnlyByTheAccountThatMadeThem() async throws {
        let harness = Harness()
        let foreign = RemoteAsset(url: URL(string: "https://upload.example/other-account")!)
        await harness.cache.store(
            foreign, contentHash: cacheKey("video", owner: "key-b"), uploadedAt: harness.clock.now)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(await harness.provider.uploads.contains("video"))
        #expect(done.inputs?.video != foreign)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SubmitAttemptTests {
    @Test func interruptedSubmitWithoutIdempotencyIsNotSentAgainAfterRelaunch() async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.hang])
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }
        await first.stop()
        let stored = try #require(await harness.repository.job(id: job.id))
        #expect(stored.state == .waitingForSlot)
        #expect(stored.submitAttempt == SubmitAttempt(isIdempotent: false))

        let second = try await harness.makeEngine()
        await harness.repository.wait(for: job.id, .failed(reason: .submitCutOff))

        #expect(await harness.provider.submitKeys.count == 1)
        await eventually { await second.limiter.inUse == 0 }
    }

    @Test func interruptedIdempotentSubmitIsSentAgainWithItsKey() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.hang])
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }
        await first.stop()
        #expect(await harness.repository.job(id: job.id)?.submitAttempt == SubmitAttempt(isIdempotent: true))

        _ = try await harness.makeEngine()
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
        #expect(done.submitAttempt == nil)
    }

    @Test func refusedSubmitWithoutIdempotencyIsTriedAgain() async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.fail(.concurrencyLimit(max: nil))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(await harness.provider.submitKeys.count == 2)
        #expect(done.submitAttempt == nil)
    }

    @Test func cancelDuringASubmitWithoutIdempotencyFailsAsUnknown() async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.hang])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }

        try await engine.cancel(job.id)

        #expect(await harness.repository.job(id: job.id)?.state == .failed(reason: .outcomeUnknown))
        await eventually { await engine.limiter.inUse == 0 }
        #expect(await harness.provider.submitKeys.count == 1)
    }

    @Test func cancelDuringAnIdempotentSubmitIsRefusedAndTheSubmitGoesOn() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.hang])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }

        await #expect(throws: JobEngineError.submitInProgress) { try await engine.cancel(job.id) }

        let stored = try #require(await harness.repository.job(id: job.id))
        #expect(stored.state == .waitingForSlot)
        #expect(stored.submitAttempt == SubmitAttempt(isIdempotent: true))
        #expect(await engine.runners[job.id] != nil)
        await engine.stop()
    }

    /// A submit answered while a cancel stops its task keeps the paid request: the cancel then reaches the server
    /// instead of failing the job as may-have-started.
    @Test func aSubmitAnsweredDuringACancelKeepsItsRequest() async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(false)
        let answer = Gate<Void>()
        await harness.provider.script(submit: [.answer(after: answer)])
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }

        let canceling = Task { try await engine.cancel(job.id) }
        await eventually { await engine.runners[job.id] == nil }
        await answer.open(.success(()))
        try await canceling.value

        let stored = try #require(await harness.repository.job(id: job.id))
        #expect(stored.state == .canceled)
        #expect(stored.remote?.requestID == "r1")
        #expect(await harness.provider.cancels == ["r1"])
    }

    /// A submit with the key whose answer was lost may be running: the job keeps resending it with that key, and
    /// can't be canceled as never sent, even once it pauses for failing.
    @Test func aLostAnswerKeepsTheSubmitMarker() async throws {
        let harness = Harness()
        await harness.provider.script(submit: Array(repeating: .fail(.network), count: 100))
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())

        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.keptFailing)))

        #expect(paused.submitAttempt == SubmitAttempt(isIdempotent: true))
        #expect(Set(await harness.provider.submitKeys) == [job.idempotencyKey])
        await #expect(throws: JobEngineError.submitInProgress) { try await engine.cancel(job.id) }
        await engine.stop()
    }

    /// The pause cuts the submit off; the job keeps its marker, so the resend after the pause uses the same key.
    private func pauseDuringAnIdempotentSubmit(_ harness: Harness) async throws -> (JobEngine, Job) {
        await harness.provider.script(submit: [.hang])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }
        await engine.setProvider(FakeProvider(owner: "key-b", log: CallLog()))
        let paused = try #require(await harness.repository.job(id: job.id))
        #expect(paused.state == .paused(.connectionNeedsAttention))
        #expect(paused.submitAttempt == SubmitAttempt(isIdempotent: true))
        return (engine, job)
    }

    @Test func connectionSwitchDuringASubmitResendsItWithItsKeyOnReturn() async throws {
        let harness = Harness()
        let (engine, job) = try await pauseDuringAnIdempotentSubmit(harness)

        await engine.setProvider(harness.provider)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
        #expect(await harness.provider.acceptedCount == 1)
        #expect(done.submitAttempt == nil)
    }

    @Test func cancelOfAJobPausedDuringItsSubmitWaitsForItsConnection() async throws {
        let harness = Harness()
        let (engine, job) = try await pauseDuringAnIdempotentSubmit(harness)

        await #expect(throws: JobEngineError.submitInProgress) { try await engine.cancel(job.id) }

        #expect(await harness.repository.job(id: job.id)?.state == .paused(.connectionNeedsAttention))
        #expect(await harness.provider.submitKeys.count == 1)
    }

    @Test func retryAfterAnUnknownOutcomeResendsTheSameKey() async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.fail(.outcomeUnknown)])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .failed(reason: .outcomeUnknown))

        try await engine.retry(job.id)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.idempotencyKey == job.idempotencyKey)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DownloadRetryTests {
    @Test func retryAfterAFailedDownloadFetchesThePaidResultWithoutGeneratingAgain() async throws {
        let harness = Harness(download: .refuse([404]))
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        let failed = try #require(
            await harness.repository.wait(for: job.id, .failed(reason: .outputUnavailable)))
        #expect(failed.hasPaidOutput)

        try await engine.retry(job.id)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
        #expect(await harness.provider.acceptedCount == 1)
        #expect(done.idempotencyKey == job.idempotencyKey)
        #expect(done.remote == failed.remote)
        #expect(done.chargedAt == failed.chargedAt)
        #expect(harness.log.count("download") == 2)
        let output = try #require(done.outputFile)
        #expect(try Data(contentsOf: output) == Data("video".utf8))
    }

    @Test func retryAfterACanceledDownloadDownloadsAgain() async throws {
        let harness = Harness(download: .hang)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .downloading)
        try await engine.cancel(job.id)

        try await engine.retry(job.id)
        await harness.repository.wait { $0.history[job.id]?.drop { $0 != .canceled }.contains(.downloading) == true }

        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
        #expect(harness.log.count("prepareVideo") == 1)
        await engine.stop()
    }

    @Test func expiredResultFailsWithAClearMessage() async throws {
        let harness = Harness(download: .refuse([404]))
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        let reason = JobState.failed(reason: .outputUnavailable)
        await harness.repository.wait(for: job.id, reason)
        await harness.provider.script(status: [.failure(.validation(field: nil, message: "Not found"))])

        try await engine.retry(job.id)
        await harness.repository.wait { $0.history[job.id]?.filter { $0 == reason }.count == 2 }

        #expect(harness.log.count("download") == 1)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
    }

    @Test(arguments: [408, 429])
    func aThrottledDownloadIsRetriedAndResumed(status: Int) async throws {
        let harness = Harness(download: .refuse([status]))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("download") == 2)
        #expect(harness.clock.sleeps.contains(5))
        #expect(done.outputFile != nil)
    }

    @Test func aRefusalOfAFreshResultAsksForANewURL() async throws {
        let harness = Harness(download: .refuse([403]))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .done)

        #expect(harness.log.count("download") == 2)
        #expect(await harness.provider.statusCalls == 2)
    }

    @Test func aRefusalOfAResultOlderThanItsLifetimeMeansItExpired() async throws {
        let harness = Harness(download: .refuse([404, 403]))
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        let reason = JobState.failed(reason: .outputUnavailable)
        await harness.repository.wait(for: job.id, reason)
        harness.clock.advance(by: JobEngine.resultLifetime + 60)

        try await engine.retry(job.id)
        await harness.repository.wait { $0.history[job.id]?.filter { $0 == reason }.count == 2 }

        #expect(harness.log.count("download") == 2)
    }

    @Test func anotherClientErrorFailsWithItsStatus() async throws {
        let harness = Harness(download: .refuse([400]))
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())

        let failed = try #require(
            await harness.repository.wait(for: job.id, .failed(reason: .message(JobEngine.downloadRefusedReason(400)))))

        #expect(failed.hasPaidOutput)
        #expect(!FileManager.default.fileExists(atPath: await engine.partialDownload(of: job.id).path))
    }

    @Test func aDownloadFinishesInTheFolderItStartedIn() async throws {
        let harness = Harness(download: .hangOnce)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .downloading)
        let partial = JobEngine.partialFile(of: job.id, in: harness.outputDirectory)
        await eventually { FileManager.default.fileExists(atPath: partial.path) }
        let moved = harness.outputDirectory.appendingPathComponent("moved")

        await engine.setOutputDirectory(moved)
        await engine.stop()
        try await engine.start()
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.downloader.starts.all == ["0", "3"])
        let output = try #require(done.outputFile)
        #expect(output.deletingLastPathComponent().lastPathComponent == harness.outputDirectory.lastPathComponent)
        #expect(try Data(contentsOf: output) == Data("video".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(done.downloadFolder == nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct InterleavedWriteTests {
    @Test func runNextDuringASubmitKeepsTheSubmitMarker() async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.hang])
        let gates = await harness.repository.holdSave { $0.submitAttempt != nil }
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        try await gates.reached.wait()

        let promoting = Task { try await engine.runNext(job.id) }
        await eventually { await engine.writeTurns.hasWaiters(for: job.id) }
        await gates.release.open(.success(()))
        try await promoting.value

        let stored = try #require(await harness.repository.job(id: job.id))
        #expect(stored.submitAttempt == SubmitAttempt(isIdempotent: false))
        #expect(stored.promotedAt != nil)

        await eventually { await harness.provider.submitKeys.count == 1 }
        await engine.stop()
        _ = try await harness.makeEngine()
        await harness.repository.wait(for: job.id, .failed(reason: .submitCutOff))
        #expect(await harness.provider.submitKeys.count == 1)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct StopTests {
    @Test func startAfterStopResumesTheJobs() async throws {
        let harness = Harness(download: .hangOnce)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { harness.downloader.starts.all.count == 1 }

        await engine.stop()
        #expect(await engine.runners.isEmpty)
        try await engine.start()

        await harness.repository.wait(for: job.id, .done)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
    }

    /// Quitting while a submit waits for its answer lets the answer arrive, with or without an idempotency key.
    @Test(arguments: [true, false])
    func stopLetsASubmitInFlightBeAnswered(isIdempotent: Bool) async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(isIdempotent)
        let answer = Gate<Void>()
        await harness.provider.script(submit: [.answer(after: answer)])
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }

        let stopping = Task { await engine.stop(finishingSubmitsWithin: .seconds(30)) }
        await eventually { await engine.submits.waiterCount == 1 }
        await answer.open(.success(()))
        await stopping.value

        await harness.provider.hold(nil)
        let stored = try #require(await harness.repository.job(id: job.id))
        #expect(stored.state == .queued)
        #expect(stored.submitAttempt == nil)
        #expect(stored.remote?.requestID == "r1")
        _ = try await harness.makeEngine()
        await harness.repository.wait(for: job.id, .done)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
    }

    @Test func stopSendsNoNewSubmitWhileItWaits() async throws {
        let harness = Harness()
        let answer = Gate<Void>()
        await harness.provider.script(submit: [.answer(after: answer)])
        let engine = try await harness.makeEngine()
        let first = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }

        let stopping = Task { await engine.stop(finishingSubmitsWithin: .seconds(30)) }
        await eventually { await engine.submits.waiterCount == 1 }
        let second = try await engine.enqueue(makeSpec())
        await eventually { await engine.runners[second.id] == nil }
        await answer.open(.success(()))
        await stopping.value

        #expect(await harness.provider.submitKeys == [first.idempotencyKey])
        let waiting = try #require(await harness.repository.job(id: second.id))
        #expect(waiting.state == .waitingForSlot)
        #expect(waiting.submitAttempt == nil)
        _ = try await harness.makeEngine()
        await harness.repository.wait(for: second.id, .done)
        #expect(await harness.provider.submitKeys == [first.idempotencyKey, second.idempotencyKey])
    }

    @Test func stopCutsOffAnIdempotentSubmitAfterItsGraceAndTheNextStartResendsIt() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.hang])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }

        await engine.stop(finishingSubmitsWithin: .milliseconds(50))

        #expect(await engine.runners.isEmpty)
        #expect(await harness.repository.job(id: job.id)?.submitAttempt == SubmitAttempt(isIdempotent: true))
        _ = try await harness.makeEngine()
        let done = try #require(await harness.repository.wait(for: job.id, .done))
        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
        #expect(await harness.provider.acceptedCount == 1)
        #expect(done.submitAttempt == nil)
    }

    @Test func stopCutsOffASubmitWithoutIdempotencyAfterItsGraceAndTheNextStartFailsIt() async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.hang])
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }

        await engine.stop(finishingSubmitsWithin: .milliseconds(50))

        #expect(await harness.repository.job(id: job.id)?.submitAttempt == SubmitAttempt(isIdempotent: false))
        let second = try await harness.makeEngine()
        let failed = try #require(
            await harness.repository.wait(for: job.id, .failed(reason: .submitCutOff)))
        #expect(failed.submitAttempt == SubmitAttempt(isIdempotent: false))
        #expect(await harness.provider.submitKeys.count == 1)
        await eventually { await second.limiter.inUse == 0 }
    }
}
