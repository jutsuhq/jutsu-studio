import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

private let cdn = "https://cdn.example"

private let reused = RemoteInputs(
    video: RemoteAsset(url: URL(string: "\(cdn)/in.mp4")!, id: "media-v"),
    images: [RemoteAsset(url: URL(string: "\(cdn)/a.png")!, id: "media-a")])

/// A spec whose inputs are already on the provider, as Edit inputs on a history item makes it.
private func reusingSpec() -> JobSpec {
    let source = SourceClip(
        fileURL: reused.video!.url, duration: 8, pixelSize: PixelSize(width: 1080, height: 1920), range: 0...8)
    return JobSpec(
        mode: .objectSwap, source: source, references: reused.images.map { LocalImage(fileURL: $0.url) },
        resolution: .p720, remoteInputs: reused)
}

private func historyItem() -> HistoryItem {
    HistoryItem(
        id: "remote-1", mode: .objectSwap, model: .genjutsu, createdAt: Date(timeIntervalSince1970: 1_791_032_606),
        outputURL: URL(string: "\(cdn)/out.mp4")!, duration: 8, inputs: reused)
}

@Suite(.timeLimit(.minutes(1)))
struct HistoryEngineTests {
    @Test func reusedMediaIDsAreSentWithoutPreparingOrUploading() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(reusingSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(await harness.provider.submittedInputs == [reused])
        #expect(harness.log.count("prepareVideo") == 0)
        #expect(harness.log.count("upload") == 0)
        #expect(done.inputs == reused)
        #expect(done.spec.remoteInputs == reused)
    }

    @Test func refusedMediaIDsAreDownloadedAndUploadedAgainOnce() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.validation(field: nil, message: "Media not found"))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(reusingSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        let submitted = await harness.provider.submittedInputs
        #expect(submitted.count == 2)
        #expect(submitted.first == reused)
        #expect(submitted.last?.video?.url.host == "upload.example")
        #expect(done.spec.remoteInputs == nil)
        let afterRefusal = harness.log.all.drop { $0 != "submit" }.dropFirst()
        #expect(
            Array(
                afterRefusal.filter { ["download", "prepareVideo", "prepareImage", "upload"].contains($0) }.prefix(6))
                == ["download", "prepareVideo", "download", "prepareImage", "upload", "upload"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("jutsu-\(job.id.uuidString)") }
        #expect(leftovers.isEmpty)
    }

    @Test func aSecondRefusalFailsTheJob() async throws {
        let harness = Harness()
        let refusal = FakeProvider.SubmitStep.fail(.validation(field: nil, message: "Media not found"))
        await harness.provider.script(submit: [refusal, refusal])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(reusingSpec())
        await harness.repository.wait(for: job.id, .failed(reason: .message("Media not found")))

        #expect(await harness.provider.submittedInputs.count == 2)
    }

    @Test func importDownloadsTheResultOnceAndSavesAFinishedJob() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()
        let item = historyItem()
        let job = Job(importing: item, owner: "user_1", importedAt: harness.clock.now)

        let imported = try await engine.importFinished(job, from: item.outputURL)
        let again = try await engine.importFinished(job, from: item.outputURL)

        let output = try #require(imported.outputFile)
        #expect(output.deletingLastPathComponent().lastPathComponent == harness.outputDirectory.lastPathComponent)
        #expect(try Data(contentsOf: output) == Data("video".utf8))
        #expect(imported.state == .done && imported.remote?.requestID == "remote-1")
        #expect(await harness.repository.job(id: job.id) == imported)
        #expect(again == imported)
        #expect(harness.log.count("download") == 1)
        let partial = await engine.partialDownload(of: job.id)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func expiredResultIsNotImported() async throws {
        let harness = Harness(download: .refuse([404]))
        let engine = try await harness.makeEngine()
        let item = historyItem()
        let job = Job(importing: item, owner: "user_1", importedAt: harness.clock.now)

        await #expect(throws: FailureReason.outputUnavailable) {
            try await engine.importFinished(job, from: item.outputURL)
        }
        #expect(await harness.repository.job(id: job.id) == nil)
    }

    @Test func aThrottledImportCanBeTriedAgain() async throws {
        let harness = Harness(download: .refuse([429]))
        let engine = try await harness.makeEngine()
        let item = historyItem()
        let job = Job(importing: item, owner: "user_1", importedAt: harness.clock.now)

        await #expect(throws: ProviderError.server(status: 429)) {
            try await engine.importFinished(job, from: item.outputURL)
        }
        let imported = try await engine.importFinished(job, from: item.outputURL)

        #expect(imported.outputFile != nil)
    }

    @Test func aRunningImportKeepsItsPartialFileThroughARestart() async throws {
        let harness = Harness(download: .hang)
        let engine = try await harness.makeEngine()
        let item = historyItem()
        let job = Job(importing: item, owner: "user_1", importedAt: harness.clock.now)
        let importing = Task { try await engine.importFinished(job, from: item.outputURL) }
        let partial = await engine.partialDownload(of: job.id)
        await eventually { FileManager.default.fileExists(atPath: partial.path) }

        await engine.stop()
        try await engine.start()

        #expect(FileManager.default.fileExists(atPath: partial.path))
        importing.cancel()
        _ = await importing.result
    }

    /// A second import of a job whose import is running (an agent's `still_working` retry) waits for that one: it
    /// never starts a second download of the same result.
    @Test func aSecondImportOfTheSameJobWaitsForTheRunningOne() async throws {
        let release = Gate<Void>()
        let harness = Harness(download: .holdOnce(release))
        let engine = try await harness.makeEngine()
        let item = historyItem()
        let job = Job(importing: item, owner: "user_1", importedAt: harness.clock.now)
        let first = Task { try await engine.importFinished(job, from: item.outputURL) }
        await eventually { harness.log.count("download") == 1 }

        // Sent while the first downloads; on its own it would download at once.
        let started = Gate<Void>()
        let second = Task {
            await started.open(.success(()))
            return try await engine.importFinished(job, from: item.outputURL)
        }
        try await started.wait()
        await release.open(.success(()))

        let imported = try await first.value
        #expect(try await second.value.id == imported.id)
        #expect(imported.outputFile != nil)
        #expect(harness.log.count("download") == 1)
    }

    @Test func anAbandonedImportPartialIsDeletedOnTheNextStart() async throws {
        let harness = Harness(download: .refuse([429]))
        let engine = try await harness.makeEngine()
        let item = historyItem()
        let job = Job(importing: item, owner: "user_1", importedAt: harness.clock.now)
        let partial = await engine.partialDownload(of: job.id)
        await #expect(throws: ProviderError.server(status: 429)) {
            try await engine.importFinished(job, from: item.outputURL)
        }
        try Data("vid".utf8).write(to: partial)

        _ = try await harness.makeEngine()

        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    /// Issue #134: `show_generations` params said 854×480 and 5 s of a 480×854, 3.71 s Edit; the file decides.
    @Test func anImportKeepsTheFilesOwnLengthAndSizeOverTheParams() async throws {
        let file = OutputMedia(duration: 3.71, pixelSize: PixelSize(width: 480, height: 854))
        var harness = Harness()
        harness.outputMedia = file
        let engine = try await harness.makeEngine()
        var item = historyItem()
        item.duration = 5
        item.pixelSize = PixelSize(width: 854, height: 480)
        let job = Job(importing: item, owner: "user_1", importedAt: harness.clock.now)
        #expect(job.outputDuration == 5)

        let imported = try await engine.importFinished(job, from: item.outputURL)

        #expect(imported.outputMedia == file)
        #expect(imported.outputDuration == 3.71)
        #expect(imported.outputPixelSize == file.pixelSize)
        #expect(await harness.repository.job(id: job.id)?.outputMedia == file)
    }

    @Test func aGeneratedJobKeepsItsFilesOwnLength() async throws {
        let file = OutputMedia(duration: 7.5, pixelSize: PixelSize(width: 720, height: 1280))
        var harness = Harness()
        harness.outputMedia = file
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(reusingSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.outputMedia == file)
        #expect(done.outputDuration == 7.5)
    }

    @Test func aResultThatCantBeReadFallsBackToTheSpec() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(reusingSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.outputMedia == nil)
        #expect(done.outputDuration == 8)
        #expect(done.outputPixelSize == PixelSize(width: 1080, height: 1920))
    }
}
