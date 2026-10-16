import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

@Suite(.timeLimit(.minutes(1)))
struct JobEngineTests {
    @Test func happyPathSavesEveryStateBeforeTheNextStep() async throws {
        let harness = Harness()
        await harness.provider.script(status: [.success(.queued), .success(.inProgress)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(
            harness.log.all == [
                "estimate", "save preparing", "prepareVideo", "prepareImage", "save uploading", "upload", "upload",
                "save waitingForSlot", "save waitingForSlot", "submit", "save queued", "status", "status",
                "save processing", "status",
                // The second save records the folder the download goes to.
                "save downloading", "save downloading", "download", "restoreAudio", "save done",
            ])
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
        #expect(done.remote?.requestID == "r1")
        #expect(done.finishedAt != nil)
        let output = try #require(done.outputFile)
        #expect(output.deletingLastPathComponent().lastPathComponent == harness.outputDirectory.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let name = output.lastPathComponent
        #expect(name.hasSuffix("_motionTransfer_\(job.id.uuidString.prefix(8).lowercased()).mp4"))
        #expect(name.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression) != nil)

        for await event in engine.events where event.id == job.id && event.state == .done { break }
    }

    @Test func aClipWithoutASourceUploadsOnlyItsImages() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()
        let spec = JobSpec(
            mode: .motionTransfer, model: .seedance25, source: nil,
            references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref0.png"))], prompt: "a fox in the snow",
            resolution: .p720, length: 8, aspectRatio: .landscape)

        let job = try await engine.enqueue(spec)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("prepareVideo") == 0)
        #expect(harness.log.count("prepareImage") == 1)
        #expect(harness.log.count("upload") == 1)
        let submitted = try #require(await harness.provider.submittedInputs.first)
        #expect(submitted.video == nil)
        #expect(submitted.images.count == 1)
        #expect(done.outputFile != nil)
    }

    @Test func enqueueKeepsTheParent() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()
        let parent = UUID()

        let job = try await engine.enqueue(makeSpec(), parentID: parent)

        #expect(job.parentID == parent)
        #expect(try await engine.enqueue(makeSpec()).parentID == nil)
    }

    @Test func batchJobsKeepTheirBatchAndShareTheSlotLimit() async throws {
        let harness = Harness(maxConcurrency: 2)
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let batch = UUID()

        var jobs: [Job] = []
        for _ in 0..<3 { jobs.append(try await engine.enqueue(makeSpec(), batchID: batch)) }
        #expect(jobs.allSatisfy { $0.batchID == batch })
        #expect(try await engine.enqueue(makeSpec()).batchID == nil)
        await harness.repository.wait { $0.count(in: .queued) == 2 }
        await quiesce()
        #expect(await harness.provider.acceptedCount == 2)

        await harness.provider.hold(nil)
        for job in jobs { await harness.repository.wait(for: job.id, .done) }
        #expect(await harness.provider.maxInFlight == 2)
    }

    @Test func settingsApplyWithoutRestart() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "JobEngineTests-\(UUID().uuidString)")
        await engine.setOutputDirectory(folder)
        await engine.setMaxConcurrency(5)

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        let output = try #require(done.outputFile)
        #expect(output.deletingLastPathComponent().lastPathComponent == folder.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(await engine.limiter.limit == 5)
    }

    @Test func namePatternAppliesToNewResultsWithoutOverwriting() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()
        let first = try await engine.enqueue(makeSpec())
        let firstDone = try #require(await harness.repository.wait(for: first.id, .done))

        await engine.setOutputNamePattern(OutputNamePattern("{mode}"))
        var names: [String] = []
        for _ in 0..<2 {
            let job = try await engine.enqueue(makeSpec())
            let done = try #require(await harness.repository.wait(for: job.id, .done))
            names.append(try #require(done.outputFile).lastPathComponent)
        }

        #expect(names == ["motionTransfer.mp4", "motionTransfer-2.mp4"])
        let firstOutput = try #require(firstDone.outputFile)
        #expect(firstOutput.lastPathComponent.hasSuffix("_\(first.id.uuidString.prefix(8).lowercased()).mp4"))
        #expect(FileManager.default.fileExists(atPath: firstOutput.path))
    }

    @Test func neverSubmitsMoreJobsThanSlots() async throws {
        let harness = Harness(maxConcurrency: 2)
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()

        var ids: [UUID] = []
        for _ in 0..<3 { ids.append(try await engine.enqueue(makeSpec()).id) }
        await harness.repository.wait { $0.count(in: .queued) == 2 }
        await eventually { await harness.provider.acceptedCount == 2 }
        #expect(await harness.provider.acceptedCount == 2)
        #expect(await engine.limiter.inUse == 2)

        await harness.provider.hold(nil)
        for id in ids { await harness.repository.wait(for: id, .done) }
        #expect(await harness.provider.maxInFlight == 2)
        #expect(await harness.provider.acceptedCount == 3)
    }

    @Test func concurrencyErrorRequeuesAndAdoptsTheReportedLimit() async throws {
        let harness = Harness(maxConcurrency: 4)
        await harness.provider.script(submit: [.fail(.concurrencyLimit(max: 1))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .done)

        let states = await harness.repository.states(of: job.id)
        // Per submit: the transition in, the attempt marker, and clearing it after the refusal; then the retry.
        #expect(states.filter { $0 == .waitingForSlot }.count == 6)
        #expect(await engine.limiter.limit == 1)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
    }

    @Test func resumeAfterCrashPollsWithoutResubmitting() async throws {
        let harness = Harness()
        await harness.provider.hold(.queued)
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .queued)
        await first.stop()

        await harness.provider.hold(nil)
        let second = try await harness.makeEngine()
        await harness.repository.wait(for: job.id, .done)

        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
        #expect(harness.log.count("prepareVideo") == 1)
        #expect(await second.limiter.inUse == 0)
    }

    @Test func aFailedLoadLeavesTheEngineStoppedSoStartCanRunAgain() async throws {
        let harness = Harness()
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .queued)
        await engine.stop()

        await harness.provider.hold(nil)
        await harness.repository.failNextLoad()
        await #expect(throws: InMemoryRepository.LoadFailed.self) { try await engine.start() }
        try await engine.start()
        await harness.repository.wait(for: job.id, .done)

        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
    }

    @Test func resumeAfterLostSubmitResponseResubmitsWithTheSameKey() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.hang])
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await eventually { await harness.provider.submitKeys.count == 1 }
        await first.stop()
        #expect(await harness.repository.job(id: job.id)?.state == .waitingForSlot)

        _ = try await harness.makeEngine()
        await harness.repository.wait(for: job.id, .done)

        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
        #expect(await harness.provider.acceptedCount == 1)
        #expect(await harness.provider.uploads.count == 2)
    }

    @Test func freshUploadCacheEntriesSkipTheUpload() async throws {
        let harness = Harness()
        let cachedVideo = RemoteAsset(url: URL(string: "https://upload.example/cached-video")!)
        await harness.cache.store(cachedVideo, contentHash: cacheKey("video"), uploadedAt: harness.clock.now)
        let stale = RemoteAsset(url: URL(string: "https://upload.example/stale")!)
        await harness.cache.store(stale, contentHash: cacheKey("image-ref0.jpg"), uploadedAt: harness.clock.now - 7200)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(await harness.provider.uploads == ["image-ref0.jpg"])
        #expect(done.inputs?.video == cachedVideo)
        #expect(done.inputs?.images.first != stale)
    }

    @Test func insufficientFundsPausesUntilResumed() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.insufficientFunds)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .paused(.insufficientFunds))
        await eventually { await engine.limiter.inUse == 0 }
        #expect(await harness.repository.job(id: job.id)?.state == .paused(.insufficientFunds))

        try await engine.resume(job.id)
        await harness.repository.wait(for: job.id, .done)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
        #expect(await harness.provider.uploads.count == 2)
    }

    @Test func unauthorizedBeforeSubmitPausesUntilTheConnectionIsBack() async throws {
        let harness = Harness()
        await harness.provider.failUploads([.unauthorized])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .paused(.connectionNeedsAttention))

        await engine.setProvider(harness.provider)
        await harness.repository.wait(for: job.id, .done)
    }

    @Test func unauthorizedAfterSubmitKeepsStateAndStopsPolling() async throws {
        let harness = Harness()
        await harness.provider.script(status: [.failure(.unauthorized)])
        let engine = try await harness.makeEngine()

        let asked = CallLog()
        await engine.onConnectionNeedsAttention { asked.append("sign in") }

        let job = try await engine.enqueue(makeSpec())
        await eventually { await harness.provider.statusCalls == 1 }
        await quiesce()
        #expect(await harness.provider.statusCalls == 1)
        #expect(await harness.repository.job(id: job.id)?.state == .queued)
        // The job shows no change, so the app is told to ask for the sign-in.
        #expect(asked.count("sign in") == 1)

        await engine.setProvider(harness.provider)
        await harness.repository.wait(for: job.id, .done)
    }

    @Test func connectionToAnotherProviderPausesUnsubmittedJobs() async throws {
        let harness = Harness(online: false)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .uploading)

        await engine.setProvider(FakeProvider(kind: .account, log: CallLog()))
        #expect(await harness.repository.job(id: job.id)?.state == .paused(.connectionNeedsAttention))

        harness.connectivity.set(online: true)
        await engine.setProvider(harness.provider)
        await harness.repository.wait(for: job.id, .done)
    }

    @Test func offlineHoldsNetworkWorkUntilReconnected() async throws {
        let harness = Harness(online: false)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .uploading)
        await quiesce()
        #expect(harness.log.count("upload") == 0)
        #expect(await harness.repository.job(id: job.id)?.state == .uploading)

        harness.connectivity.set(online: true)
        await harness.repository.wait(for: job.id, .done)
    }

    @Test func networkErrorsRetryWithBackoff() async throws {
        let harness = Harness()
        await harness.provider.failUploads([.network, .server(status: 503)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .done)

        #expect(harness.log.count("upload") == 4)
        #expect(Array(harness.clock.sleeps.prefix(2)) == [5, 10])
    }

    @Test func validationErrorFailsWithTheMessage() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.validation(field: "prompt", message: "Prompt is too long"))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .failed(reason: .message("Prompt is too long")))
        await eventually { await engine.limiter.inUse == 0 }
    }

    @Test func submitWithUnknownOutcomeFailsWithoutResending() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.outcomeUnknown)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .failed(reason: .outcomeUnknown))
        #expect(harness.log.count("submit") == 1)
        await eventually { await engine.limiter.inUse == 0 }
    }

    @Test func remoteRejectionEndsAsRejected() async throws {
        let harness = Harness()
        await harness.provider.script(status: [.success(.rejected(.protectedContent))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let rejected = await harness.repository.wait(for: job.id, .rejected)
        #expect(rejected?.rejection == .protectedContent)
        #expect(await engine.limiter.inUse == 0)
    }

    @Test func cancelBeforeSubmitIsLocal() async throws {
        let harness = Harness(online: false)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .uploading)

        try await engine.cancel(job.id)
        harness.connectivity.set(online: true)
        await quiesce()

        #expect(await harness.repository.job(id: job.id)?.state == .canceled)
        #expect(await harness.repository.job(id: job.id)?.chargedAt == nil)
        #expect(await harness.provider.cancels.isEmpty)
        #expect(await harness.provider.submitKeys.isEmpty)
    }

    @Test func cancelWhileQueuedCancelsRemotely() async throws {
        let harness = Harness()
        await harness.provider.hold(.queued)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .queued)

        try await engine.cancel(job.id)

        #expect(await harness.repository.job(id: job.id)?.state == .canceled)
        #expect(await harness.provider.cancels == ["r1"])
        #expect(await engine.limiter.inUse == 0)
    }

    @Test func cancelWhileProcessingIsRefused() async throws {
        let harness = Harness()
        await harness.provider.hold(.inProgress)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .processing)

        await #expect(throws: JobEngineError.notCancellable(.processing)) { try await engine.cancel(job.id) }

        await harness.provider.hold(nil)
        await harness.repository.wait(for: job.id, .done)
        #expect(await harness.provider.cancels.isEmpty)
    }

    @Test func aJobCanceledOnTheServerWhileQueuedIsCanceled() async throws {
        let harness = Harness()
        await harness.provider.script(status: [.success(.canceled)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())

        await harness.repository.wait(for: job.id, .canceled)
        await eventually { await engine.limiter.inUse == 0 }
    }

    @Test func aJobCanceledOnTheServerWhileProcessingFails() async throws {
        let harness = Harness()
        await harness.provider.script(status: [.success(.inProgress), .success(.canceled)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())

        await harness.repository.wait(for: job.id, .failed(reason: .canceledOnServer))
        await eventually { await engine.limiter.inUse == 0 }
    }

    @Test func cancelWhileDownloadingIsLocalAndRemovesThePartialFile() async throws {
        let harness = Harness(download: .hang)
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .downloading)
        let partial = await engine.partialDownload(of: job.id)
        await eventually { FileManager.default.fileExists(atPath: partial.path) }

        try await engine.cancel(job.id)

        let canceled = try #require(await harness.repository.job(id: job.id))
        #expect(canceled.state == .canceled)
        #expect(canceled.chargedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(await harness.provider.cancels.isEmpty)
        #expect(await engine.limiter.inUse == 0)
    }

    @Test func interruptedDownloadResumesFromThePartialFile() async throws {
        let harness = Harness(download: .dropOnce)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.downloader.starts.all == ["0", "3"])
        let output = try #require(done.outputFile)
        #expect(try Data(contentsOf: output) == Data("video".utf8))
        #expect(!FileManager.default.fileExists(atPath: await engine.partialDownload(of: job.id).path))
    }

    @Test func resultWithRestoredAudioReplacesTheDownload() async throws {
        let harness = Harness(audio: .mux)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        let output = try #require(done.outputFile)
        #expect(try Data(contentsOf: output) == Data("video+audio".utf8))
        #expect(!FileManager.default.fileExists(atPath: await engine.partialDownload(of: job.id).path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.outputDirectory.path)
        #expect(leftovers == [output.lastPathComponent])
    }

    @Test func failedAudioRestoreKeepsTheSilentResult() async throws {
        let harness = Harness(audio: .fail)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        let output = try #require(done.outputFile)
        #expect(try Data(contentsOf: output) == Data("video".utf8))
        #expect(harness.log.count("restoreAudio") == 1)
    }

    @Test func preparingProgressArrivesInOrderBeforeTheNextState() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        var seen: [String] = []
        for await event in engine.events where event.id == job.id {
            seen.append("\(event.state) \(event.progress)")
            if event.state == .uploading { break }
        }

        #expect(seen == ["preparing 0.0", "preparing 0.5", "preparing 1.0", "uploading 0.0"])
    }

    @Test func placeReplacesAnEarlierResult() throws {
        let folder = try makeFolder()
        let destination = folder.appendingPathComponent("out.mp4")
        let partial = folder.appendingPathComponent(".out.partial")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: partial)

        let placed = try JobEngine.place(partial, at: destination)

        #expect(try Data(contentsOf: placed) == Data("new".utf8))
        #expect(placed.lastPathComponent == "out.mp4")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func failedPlaceKeepsTheEarlierResult() throws {
        let folder = try makeFolder()
        let destination = folder.appendingPathComponent("out.mp4")
        try Data("old".utf8).write(to: destination)

        #expect(throws: (any Error).self) {
            try JobEngine.place(folder.appendingPathComponent(".missing.partial"), at: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "JobEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func retryIsANewAttemptWithANewIdempotencyKey() async throws {
        let harness = Harness()
        await harness.provider.script(status: [.success(.failed(message: "Generation error"))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .failed(reason: .message("Generation error")))
        await #expect(throws: JobEngineError.notResumable(.failed(reason: .message("Generation error")))) {
            try await engine.resume(job.id)
        }

        harness.clock.advance(by: 600)
        let retriedAt = harness.clock.now
        try await engine.retry(job.id)
        let done = try #require(await harness.repository.wait(for: job.id, .done))
        #expect(done.idempotencyKey != job.idempotencyKey)
        #expect(done.attemptStartedAt == retriedAt)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey, done.idempotencyKey])
        #expect(await harness.provider.acceptedCount == 2)
    }

    @Test func retryIsOnlyForFailedOrCanceledJobs() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()
        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .done)

        await #expect(throws: JobEngineError.notRetryable(.done)) { try await engine.retry(job.id) }
        let unknown = UUID()
        await #expect(throws: JobEngineError.unknownJob(unknown)) { try await engine.cancel(unknown) }
    }
}
