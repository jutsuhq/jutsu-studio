import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

/// Images of an account element: sent by the media ID the account listed, uploaded when the provider can't take it.
@Suite(.timeLimit(.minutes(1)))
struct ServerMediaInputsTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ServerMedia-\(UUID().uuidString)")
    let mediaURL = URL(string: "https://cdn.example.org/mara.jpg")!

    /// A Motion spec over real files whose one reference is an element image of `owner`.
    func spec(owner: String? = "key-a") throws -> JobSpec {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("dance.mov")
        let image = folder.appendingPathComponent("mara.jpg")
        try Data("video".utf8).write(to: video)
        try Data("image".utf8).write(to: image)
        let source = SourceClip(
            fileURL: video, duration: 12, pixelSize: PixelSize(width: 1280, height: 720), range: 0...12)
        let media = ServerMedia(id: "m-1", url: mediaURL, owner: owner)
        return JobSpec(
            mode: .motionTransfer, source: source, references: [LocalImage(fileURL: image, serverMedia: media)],
            resolution: .p480)
    }

    @Test func anElementImageIsNamedByItsMediaIDAndNotUploaded() async throws {
        let harness = Harness()
        await harness.provider.setTakesServerMedia(true)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("upload") == 1)
        #expect(done.inputs?.images == [RemoteAsset(url: mediaURL, id: "m-1")])
    }

    @Test func anotherAccountsMediaIsUploaded() async throws {
        let harness = Harness()
        await harness.provider.setTakesServerMedia(true)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec(owner: "someone-else"))
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.log.count("upload") == 2)
        #expect(done.inputs?.images.first?.id != "m-1")
    }

    @Test func aRefusedMediaIDIsUploadedInsteadOnce() async throws {
        let harness = Harness()
        await harness.provider.setTakesServerMedia(true)
        await harness.provider.script(submit: [.fail(.validation(field: nil, message: "Unknown media"))])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(try spec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        let submitted = await harness.provider.submittedInputs
        #expect(submitted.count == 2)
        #expect(submitted.first?.images.first?.id == "m-1")
        #expect(submitted.last?.images.first?.id != "m-1")
        #expect(done.spec.references.first?.serverMedia == nil)
        #expect(await harness.provider.submitKeys == [job.idempotencyKey, job.idempotencyKey])
    }

    @Test func mediaUseIsReadFromTheInputs() throws {
        let spec = try spec()
        let named = RemoteInputs(video: nil, images: [RemoteAsset(url: mediaURL, id: "m-1")])
        let uploaded = RemoteInputs(video: nil, images: [RemoteAsset(url: URL(string: "https://upload.example/a")!)])

        #expect(JobEngine.usesServerMedia(named, of: spec))
        #expect(!JobEngine.usesServerMedia(uploaded, of: spec))
    }

    @Test func imagesStoredBeforeServerMediaStillDecode() throws {
        let image = try JSONDecoder().decode(LocalImage.self, from: Data(#"{"fileURL":"file:///tmp/a.jpg"}"#.utf8))
        #expect(image.serverMedia == nil)
    }
}
