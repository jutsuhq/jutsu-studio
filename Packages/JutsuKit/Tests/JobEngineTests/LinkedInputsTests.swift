import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

/// Inputs downloaded from a link: sent by that link where the provider takes it, uploaded otherwise.
@Suite(.timeLimit(.minutes(1)))
struct LinkedInputsTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LinkedInputs-\(UUID().uuidString)")
    let videoOrigin = URL(string: "https://cdn.example.org/dance.mp4")!
    let imageOrigin = URL(string: "https://cdn.example.org/face.png")!

    /// A spec over real files, so their size can be read; the clip is 12 s long.
    func spec(range: ClosedRange<TimeInterval> = 0...12, linked: Bool = true) throws -> JobSpec {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("dance.mp4")
        let image = folder.appendingPathComponent("face.png")
        try Data("video".utf8).write(to: video)
        try Data("image".utf8).write(to: image)
        let source = SourceClip(
            fileURL: video, duration: 12, pixelSize: PixelSize(width: 1280, height: 720), range: range,
            remoteOrigin: linked ? videoOrigin : nil)
        return JobSpec(
            mode: .motionTransfer, source: source,
            references: [LocalImage(fileURL: image, remoteOrigin: linked ? imageOrigin : nil)], resolution: .p480)
    }

    @Test func aWholeLinkedClipMakesNoUpload() async throws {
        let harness = Harness()
        await harness.provider.setTakesLinks(true)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("upload") == 0)
        #expect(await harness.provider.submittedInputs == [done.inputs].compactMap(\.self))
        #expect(
            done.inputs == RemoteInputs(video: RemoteAsset(url: videoOrigin), images: [RemoteAsset(url: imageOrigin)]))
    }

    @Test func aTrimmedClipIsUploadedAndItsLinkedImageIsNot() async throws {
        let harness = Harness()
        await harness.provider.setTakesLinks(true)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec(range: 2...10))
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("upload") == 1)
        #expect(harness.log.count("linked video") == 0)
        #expect(done.inputs?.video?.url != videoOrigin)
        #expect(done.inputs?.images == [RemoteAsset(url: imageOrigin)])
    }

    @Test func aProviderThatDoesntTakeLinksGetsUploads() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("linked video") == 1)
        #expect(harness.log.count("upload") == 2)
        #expect(done.inputs?.video?.url != videoOrigin)
    }

    @Test func pickedFilesAreNeverOfferedByLink() async throws {
        let harness = Harness()
        await harness.provider.setTakesLinks(true)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec(linked: false))
        _ = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(!harness.log.all.contains { $0.hasPrefix("linked") })
        #expect(harness.log.count("upload") == 2)
    }

    @Test func aRefusedLinkIsUploadedInstead() async throws {
        let harness = Harness()
        await harness.provider.setTakesLinks(true)
        await harness.provider.script(submit: [.fail(.validation(field: "video_url", message: "Can't fetch"))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        let submitted = await harness.provider.submittedInputs
        #expect(submitted.count == 2)
        #expect(submitted.first?.video?.url == videoOrigin)
        #expect(submitted.last?.video?.url != videoOrigin)
        #expect(harness.log.count("upload") == 2)
        #expect(done.spec.source?.remoteOrigin == nil)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
    }

    @Test func otherRefusalsOfUploadedInputsStillFail() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.validation(field: "prompt", message: "Too long"))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec(linked: false))

        #expect(await harness.repository.wait(for: job.id, .failed(reason: .message("Too long"))) != nil)
        #expect(await harness.provider.submittedInputs.count == 1)
    }

    @Test func linkUseIsReadFromTheInputs() throws {
        let spec = try spec()
        let linked = RemoteInputs(video: RemoteAsset(url: videoOrigin), images: [])
        let uploaded = RemoteInputs(video: RemoteAsset(url: URL(string: "https://upload.example/video")!), images: [])

        #expect(JobEngine.usesLinks(linked, of: spec))
        #expect(!JobEngine.usesLinks(uploaded, of: spec))
    }
}
