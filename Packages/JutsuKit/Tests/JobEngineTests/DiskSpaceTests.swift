import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private let outOfSpaceErrors: [any Error] = [
    CocoaError(.fileWriteOutOfSpace),
    POSIXError(.ENOSPC),
    URLError(.cannotWriteToFile, userInfo: [NSUnderlyingErrorKey: POSIXError(.EDQUOT)]),
]

@Suite(.timeLimit(.minutes(1)))
struct DiskSpaceTests {
    @Test(arguments: outOfSpaceErrors)
    func aFullDiskPausesTheDownloadAndResumeFinishesIt(error: any Error) async throws {
        let harness = Harness(download: .failOnce(error))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.notEnoughDiskSpace)))

        #expect(paused.remote?.requestID == "r1")
        #expect(paused.chargedAt != nil)
        #expect(paused.downloadFolder != nil)
        let partial = await engine.partialDownload(of: job.id)
        #expect(try Data(contentsOf: partial) == Data("vid".utf8))
        await eventually { await engine.limiter.inUse == 0 }

        try await engine.resume(job.id)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.downloader.starts.all == ["0", "3"])
        #expect(try Data(contentsOf: #require(done.outputFile)) == Data("video".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
    }

    @Test func aFullDiskWhileAddingTheSoundPausesInsteadOfDroppingIt() async throws {
        let harness = Harness(audio: .diskFullOnce)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .paused(.notEnoughDiskSpace))

        try await engine.resume(job.id)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(try Data(contentsOf: #require(done.outputFile)) == Data("video+audio".utf8))
        #expect(harness.log.count("restoreAudio") == 2)
    }

    @Test func aJobPausedForDiskSpaceStaysPausedAfterARelaunch() async throws {
        let harness = Harness(download: .failOnce(CocoaError(.fileWriteOutOfSpace)))
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .paused(.notEnoughDiskSpace))
        await first.stop()

        let second = try await harness.makeEngine()
        await quiesce()

        #expect(await harness.repository.job(id: job.id)?.state == .paused(.notEnoughDiskSpace))
        #expect(FileManager.default.fileExists(atPath: await second.partialDownload(of: job.id).path))
        try await second.resume(job.id)
        await harness.repository.wait(for: job.id, .done)
    }

    @Test(arguments: outOfSpaceErrors)
    func outOfSpaceErrorsAreRecognized(error: any Error) {
        #expect(JobEngine.isOutOfSpace(error))
    }

    @Test func otherWriteErrorsAreNot() {
        let errors: [any Error] = [
            CocoaError(.fileWriteNoPermission), POSIXError(.ENOENT), URLError(.cannotWriteToFile),
            ProviderError.network,
        ]
        for error in errors { #expect(!JobEngine.isOutOfSpace(error), "\(error)") }
    }
}
