import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

/// Upscale and Remove Background run through the same pipeline as a generation: a result the account made is
/// named by its job ID instead of uploaded, and the output keeps the server's container and sound, unless the server
/// dropped the sound (Remove Background), which is put back.
@Suite(.timeLimit(.minutes(1)))
struct PostOperationTests {
    let source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/result.mp4"), duration: 6, pixelSize: PixelSize(width: 1280, height: 720),
        range: 0...6)

    func spec(_ action: PostAction = .removeBackground, jobID: String? = "job-7") -> JobSpec {
        JobSpec(
            mode: .motionTransfer, source: source, resolution: .p720,
            operation: PostOperation(action: action, sourceJobID: jobID))
    }

    @Test func aResultNamedByItsJobIDIsNeitherPreparedNorUploaded() async throws {
        let harness = Harness(audio: .mux)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(spec(), parentID: UUID())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("prepareVideo") == 0)
        #expect(harness.log.count("upload") == 0)
        #expect(await harness.provider.submittedInputs == [RemoteInputs(video: nil, images: [])])
        #expect(done.spec.operation?.sourceJobID == "job-7")
        #expect(done.parentID == job.parentID)
    }

    /// A native draft's finalize names the draft by its job ID (`JobSpec.draftJobID`): the draft's inputs it keeps
    /// for the library are neither prepared nor uploaded.
    @Test func aDraftsFinalizeUploadsNothing() async throws {
        let harness = Harness(audio: .mux)
        let engine = try await harness.makeEngine()
        let finalize = JobSpec(
            mode: .motionTransfer, model: .seedance25, source: source,
            references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))], resolution: .p1080,
            draftJobID: "draft-job")

        let job = try await engine.enqueue(finalize, parentID: UUID())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("prepareVideo") == 0)
        #expect(harness.log.count("upload") == 0)
        #expect(await harness.provider.submittedInputs == [RemoteInputs(video: nil, images: [])])
        #expect(done.spec.draftJobID == "draft-job")
    }

    /// Remove Background's result came without audio in a live run on 2026-10-15, so the source's sound is put back
    /// as for a generation, cut to the result's length (`AudioPlan`), and the result is an MP4.
    @Test func aCutoutGetsTheSourcesSoundBack() async throws {
        let harness = Harness(audio: .mux)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(spec(), parentID: UUID())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("restoreAudio") == 1)
        #expect(done.outputFile?.pathExtension == "mp4")
    }

    /// A dub's sound is the point of it: the server's result is kept as it came.
    @Test func aDubKeepsTheServersSound() async throws {
        let harness = Harness(audio: .mux)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(spec(.dub(.french)), parentID: UUID())
        _ = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("restoreAudio") == 0)
    }

    @Test func withoutAJobIDTheResultFileIsUploaded() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(spec(jobID: nil))
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("upload") == 1)
        #expect(done.inputs?.video != nil)
    }

    @Test func aRefusedJobIDIsReplacedByAnUploadOnce() async throws {
        let harness = Harness()
        await harness.provider.script(submit: [.fail(.validation(field: nil, message: "Unknown job_id"))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(spec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        let submitted = await harness.provider.submittedInputs
        #expect(submitted.count == 2)
        #expect(submitted.first == RemoteInputs(video: nil, images: []))
        #expect(submitted.last?.video != nil)
        #expect(done.spec.operation?.sourceJobID == nil)
        #expect(done.spec.operation?.action == .removeBackground)
    }

    @Test func aSecondRefusalFails() async throws {
        let harness = Harness()
        let refusal = ProviderError.validation(field: nil, message: "Video too long")
        await harness.provider.script(submit: [.fail(refusal), .fail(refusal)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(spec())

        #expect(await harness.repository.wait(for: job.id, .failed(reason: .message("Video too long"))) != nil)
        #expect(await harness.provider.submittedInputs.count == 2)
    }

    @Test func theResultKeepsTheServersContainer() async throws {
        let harness = Harness()
        let output = try #require(URL(string: "https://cdn.example/cutout.MOV?sig=1"))
        await harness.provider.script(status: [.success(.completed(videoURL: output))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(spec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.outputFile?.pathExtension == "mov")
    }

    @Test func aGenerationStillGetsItsSound() async throws {
        let harness = Harness(audio: .mux)
        let engine = try await harness.makeEngine()

        var generation = spec()
        generation.operation = nil
        let job = try await engine.enqueue(generation)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("restoreAudio") == 1)
        #expect(done.outputFile?.pathExtension == "mp4")
    }
}
