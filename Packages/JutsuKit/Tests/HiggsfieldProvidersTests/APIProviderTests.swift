import Foundation
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

private let submitted = """
    {"status": "queued", "request_id": "req-123",
     "status_url": "https://api.higgsfield.ai/requests/req-123/status",
     "cancel_url": "https://api.higgsfield.ai/requests/req-123/cancel"}
    """

private let inputs = RemoteInputs(
    video: RemoteAsset(url: URL(string: "https://cdn.example.com/in.mp4")!),
    images: [RemoteAsset(url: URL(string: "https://cdn.example.com/a.jpg")!)])
private let presetID = UUID(uuidString: "c2143317-f28d-4c3c-a0b8-39bd547e08a7")!

private func spec(_ mode: Mode = .motionTransfer, presetID: UUID? = nil) -> JobSpec {
    let source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 60,
        pixelSize: PixelSize(width: 1280, height: 720), range: 0...12)
    return JobSpec(mode: mode, source: source, presetID: presetID, prompt: "", resolution: .p480)
}

@Test(arguments: [
    (Mode.motionTransfer, "/higgsfield/genjutsu/motion-transfer/v1.0"),
    (.objectSwap, "/higgsfield/genjutsu/object-swap/v1.0"),
    (.restyle, "/higgsfield/genjutsu/restyle/v1.0"),
])
func submitGoesToTheModeWorkflowAndKeepsTheReturnedURLs(mode: Mode, path: String) async throws {
    let server = StubServer()
    server.on("POST", path, StubResponse(headers: ["X-Correlation-ID": "corr-1"], body: submitted))

    let job = try await server.makeAPIProvider().submit(
        spec(mode, presetID: presetID), inputs: inputs, idempotencyKey: UUID())

    #expect(
        job
            == RemoteJob(
                requestID: "req-123", correlationID: "corr-1",
                statusURL: URL(string: "https://api.higgsfield.ai/requests/req-123/status"),
                cancelURL: URL(string: "https://api.higgsfield.ai/requests/req-123/cancel"), initialStatus: .queued))
    let body = try #require(server.requests.first?.bodyText)
    #expect(body.contains("preset_id") == (mode == .restyle))
}

@Test func restyleWithoutPresetFailsBeforeSending() async {
    let server = StubServer()
    await #expect(throws: ProviderError.validation(field: "preset_id", message: "Restyle needs a preset.")) {
        try await server.makeAPIProvider().submit(spec(.restyle), inputs: inputs, idempotencyKey: UUID())
    }
    #expect(server.requests.isEmpty)
}

@Test func clientErrorsArriveAsProviderErrors() async {
    let server = StubServer()
    server.on(
        "POST", "/higgsfield/genjutsu/motion-transfer/v1.0",
        StubResponse(status: 400, body: #"{"detail": "Maximum number of concurrent requests (2)"}"#))
    server.on("GET", "/requests/req-1/status", fail: URLError(.notConnectedToInternet))
    let provider = server.makeAPIProvider()

    await #expect(throws: ProviderError.concurrencyLimit(max: 2)) {
        try await provider.submit(spec(), inputs: inputs, idempotencyKey: UUID())
    }
    await #expect(throws: ProviderError.network) { try await provider.status(RemoteJob(requestID: "req-1")) }
}

@Test func serverEstimateIsExactUSD() async throws {
    let server = StubServer()
    server.on(
        "POST", "/estimate/higgsfield/genjutsu/motion-transfer/v1.0",
        StubResponse(body: #"{"credits": "61.000", "usd": "3.816"}"#))

    let price = try await server.makeAPIProvider().serverEstimate(spec(), inputs: inputs)

    #expect(price == .usd(Decimal(string: "3.816") ?? 0, isEstimate: false))
}

@Test func uploadReturnsThePublicURL() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("fake video".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let server = StubServer()
    server.on(
        "POST", "/files/generate-upload-url",
        StubResponse(
            body: #"""
                {"upload_url": "\#(server.baseURL.absoluteString)/bucket/in.mp4",
                 "public_url": "https://cdn.example.com/in.mp4"}
                """#))
    server.on("PUT", "/bucket/in.mp4", StubResponse())

    let asset = try await server.makeAPIProvider().upload(
        PreparedFile(fileURL: file, contentType: "video/mp4", byteCount: 10, contentHash: "abc"))

    let url = try #require(URL(string: "https://cdn.example.com/in.mp4"))
    #expect(asset == RemoteAsset(url: url))
}

@Test func presetsBecomeStylePresets() async throws {
    let server = StubServer()
    server.on(
        "GET", "/models/higgsfield/genjutsu/restyle/v1.0/presets",
        StubResponse(
            body: """
                {"items": [{"id": "\(presetID.uuidString.lowercased())", "name": "Cel-Shaded",
                            "preview_url": "https://cdn.higgsfield.ai/p.webp"}]}
                """))

    let presets = try await server.makeAPIProvider().presets()

    #expect(presets.map(\.id) == [presetID])
}

@Test func providerReportsStaticCapabilitiesAndListPrice() async throws {
    let provider = StubServer().makeAPIProvider(keyID: "kid-1")

    #expect(provider.kind == .apiKey)
    #expect(provider.owner == "kid-1")
    #expect(
        try await provider.capabilities()
            == Capabilities(
                modes: Set(Mode.allCases), models: Set(VideoModel.allCases.filter(\.runsWithAPIKey)),
                resolutions: Set(Resolution.allCases), costUnit: .usd, maxConcurrency: nil,
                parameters: Set(ModelParameter.allCases).subtracting([.klingVideoBackground])))
    #expect(try await provider.estimate(spec()) == .usd(Decimal(string: "3.816") ?? 0, isEstimate: false))
    #expect(try await provider.balance() == nil)
    #expect(try await provider.submitIsIdempotent(spec()))
}

@Test func providerPollsAndCancelsByRequestID() async throws {
    let server = StubServer()
    server.on("GET", "/requests/req-7/status", StubResponse(body: #"{"status": "nsfw", "request_id": "req-7"}"#))
    server.on("POST", "/requests/req-7/cancel", StubResponse(status: 400, body: #"{"detail": "Not queued"}"#))
    let provider = server.makeAPIProvider()
    let job = RemoteJob(requestID: "req-7")

    #expect(try await provider.status(job) == .rejected(.explicitContent))
    await #expect(throws: ProviderError.validation(field: nil, message: "Not queued")) {
        try await provider.cancel(job)
    }
}

/// A Seedance job: from a 1080×1920 source when `hasSource`, else a 9:16 clip of 8 s from the prompt.
private func seedance(hasSource: Bool, references: Int = 0, audio: AudioOption = .original) -> JobSpec {
    let images = (0..<references).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref\($0).jpg")) }
    let source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 60,
        pixelSize: PixelSize(width: 1080, height: 1920), range: 0...12)
    return JobSpec(
        mode: .motionTransfer, model: .seedance25, source: hasSource ? source : nil, references: images,
        prompt: "a fox in the snow", resolution: .p720, audio: audio, length: hasSource ? nil : 8,
        aspectRatio: hasSource ? nil : .portrait)
}

private let character = RemoteAsset(url: URL(string: "https://cdn.example.com/a.jpg")!)
private let video = RemoteAsset(url: URL(string: "https://cdn.example.com/in.mp4")!)

@Test func seedanceWithoutMediaMakesAClipFromThePrompt() async throws {
    let server = StubServer()
    server.on("POST", "/bytedance/seedance-2.5/text-to-video", StubResponse(body: submitted))

    _ = try await server.makeAPIProvider().submit(
        seedance(hasSource: false), inputs: RemoteInputs(video: nil, images: []), idempotencyKey: UUID())

    #expect(
        server.requests.first?.bodyText
            == #"{"aspect_ratio":"9:16","duration":8,"generate_audio":true,"prompt":"a fox in the snow","resolution":"720p"}"#
    )
}

@Test func seedanceWithImagesOnlyUsesThemAsReferences() async throws {
    let server = StubServer()
    server.on("POST", "/bytedance/seedance-2.5/reference-to-video", StubResponse(body: submitted))

    _ = try await server.makeAPIProvider().submit(
        seedance(hasSource: false, references: 1, audio: .mute), inputs: RemoteInputs(video: nil, images: [character]),
        idempotencyKey: UUID())

    let body = try #require(server.requests.first?.bodyText)
    #expect(body.contains(#""image_urls":["https://cdn.example.com/a.jpg"]"#))
    #expect(body.contains(#""generate_audio":false"#))
    #expect(!body.contains("video_urls"))
}

@Test func seedanceSendsTheSourceFirstAndItsFrame() async throws {
    let server = StubServer()
    server.on("POST", "/estimate/bytedance/seedance-2.5/reference-to-video", StubResponse(body: #"{"usd": "6.6"}"#))

    let price = try await server.makeAPIProvider().serverEstimate(
        seedance(hasSource: true, references: 1), inputs: RemoteInputs(video: video, images: [character]))

    #expect(price == .usd(Decimal(string: "6.6") ?? 0, isEstimate: false))
    #expect(
        server.requests.first?.bodyText
            == #"{"aspect_ratio":"9:16","duration":12,"generate_audio":false,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"a fox in the snow","resolution":"720p","video_urls":["https://cdn.example.com/in.mp4"]}"#
    )
}

@Test(arguments: [(Resolution.p480, "std"), (.p720, "std"), (.p1080, "pro")])
func klingQualityIsTheEndpoint(resolution: Resolution, quality: String) async throws {
    let server = StubServer()
    let path = "/kling-video/v3/motion-control/\(quality)"
    server.on("POST", path, StubResponse(body: submitted))
    var kling = spec()
    kling.model = .klingMotionControl
    kling.resolution = resolution
    kling.keepsVideoBackground = true

    _ = try await server.makeAPIProvider().submit(
        kling, inputs: RemoteInputs(video: video, images: [character]), idempotencyKey: UUID())

    let request = try #require(server.requests.first)
    #expect(request.path == path)
    #expect(
        request.bodyText
            == #"{"image_url":"https://cdn.example.com/a.jpg","keep_original_sound":"yes","video_url":"https://cdn.example.com/in.mp4"}"#
    )
}

/// Kling keeps the source's sound itself for Original; Mute wants none, and Fade out comes back silent so the faded
/// sound is put on after download.
@Test(arguments: [(AudioOption.original, "yes"), (.mute, "no"), (.fadeOut, "no")])
func klingSendsTheSoundAndTheOrientation(audio: AudioOption, keepsSound: String) async throws {
    let server = StubServer()
    server.on("POST", "/kling-video/v3/motion-control/pro", StubResponse(body: submitted))
    var kling = spec()
    kling.model = .klingMotionControl
    kling.resolution = .p1080
    kling.audio = audio
    kling.characterOrientation = .image

    _ = try await server.makeAPIProvider().submit(
        kling, inputs: RemoteInputs(video: video, images: [character]), idempotencyKey: UUID())

    let body = try #require(server.requests.first?.bodyText)
    #expect(body.contains(#""keep_original_sound":"\#(keepsSound)""#))
    #expect(body.contains(#""character_orientation":"image""#))
}

/// With a source, Seedance makes a soundtrack only when asked to; the bitrate goes as picked.
@Test(arguments: [(AudioOption.original, false), (.generated, true), (.mute, false)])
func seedanceWithASourceMakesItsOwnSoundOnlyWhenAsked(audio: AudioOption, generates: Bool) async throws {
    let server = StubServer()
    server.on("POST", "/bytedance/seedance-2.5/reference-to-video", StubResponse(body: submitted))
    var job = seedance(hasSource: true, audio: audio)
    job.bitrate = .standard

    _ = try await server.makeAPIProvider().submit(
        job, inputs: RemoteInputs(video: video, images: []), idempotencyKey: UUID())

    let body = try #require(server.requests.first?.bodyText)
    #expect(body.contains(#""generate_audio":\#(generates)"#))
    #expect(body.contains(#""bitrate_mode":"standard""#))
}

@Test func seedanceEditMakesItsOwnSoundWhenAsked() async throws {
    let server = StubServer()
    server.on("POST", "/bytedance/seedance-2.5/video-edit", StubResponse(body: submitted))
    var edit = seedance(hasSource: true, audio: .generated)
    edit.mode = .edit

    _ = try await server.makeAPIProvider().submit(
        edit, inputs: RemoteInputs(video: video, images: []), idempotencyKey: UUID())

    #expect(server.requests.first?.bodyText?.contains(#""generate_audio":true"#) == true)
}

/// The first reference is the start frame and the second the end frame; the frame follows the start image, so no
/// aspect ratio goes with them.
@Test func seedanceFramesRunOnImageToVideo() async throws {
    let server = StubServer()
    server.on("POST", "/bytedance/seedance-2.5/image-to-video", StubResponse(body: submitted))
    var job = seedance(hasSource: false, references: 2)
    job.referencesAreFrames = true
    let end = RemoteAsset(url: URL(string: "https://cdn.example.com/b.jpg")!)
    let provider = server.makeAPIProvider()

    _ = try await provider.submit(
        job, inputs: RemoteInputs(video: nil, images: [character, end]), idempotencyKey: UUID())

    #expect(
        server.requests.first?.bodyText
            == #"{"duration":8,"end_image_url":"https://cdn.example.com/b.jpg","generate_audio":true,"image_url":"https://cdn.example.com/a.jpg","prompt":"a fox in the snow","resolution":"720p"}"#
    )
    #expect(try await provider.estimate(job) == .usd(Decimal(string: "3.6976") ?? 0, isEstimate: true))
    await #expect(throws: ProviderError.validation(field: "image_url", message: "Seedance needs the start frame.")) {
        try await provider.submit(job, inputs: RemoteInputs(video: nil, images: []), idempotencyKey: UUID())
    }
}

@Test func klingWithoutAnImageFailsBeforeSending() async {
    let server = StubServer()
    var kling = spec()
    kling.model = .klingMotionControl

    await #expect(throws: ProviderError.validation(field: "image_url", message: "Kling needs a reference image.")) {
        try await server.makeAPIProvider().submit(
            kling, inputs: RemoteInputs(video: video, images: []), idempotencyKey: UUID())
    }
    #expect(server.requests.isEmpty)
}

/// Edit sends no length (the output follows the source) and keeps the source's sound; Extend sends the part it adds
/// and has the model make its sound.
@Test(arguments: [
    (
        Mode.edit, "/bytedance/seedance-2.5/video-edit",
        #"{"generate_audio":false,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"a fox in the snow","resolution":"720p","video_url":"https://cdn.example.com/in.mp4"}"#
    ),
    (
        .extend, "/bytedance/seedance-2.5/video-extend",
        #"{"duration":7,"generate_audio":true,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"a fox in the snow","resolution":"720p","video_url":"https://cdn.example.com/in.mp4"}"#
    ),
])
func seedanceEditAndExtendSendTheSourceAsTheClip(mode: Mode, path: String, body: String) async throws {
    let server = StubServer()
    server.on("POST", path, StubResponse(body: submitted))
    var job = seedance(hasSource: true, references: 1)
    job.mode = mode
    job.length = mode == .extend ? 7 : nil

    _ = try await server.makeAPIProvider().submit(
        job, inputs: RemoteInputs(video: video, images: [character]), idempotencyKey: UUID())

    let request = try #require(server.requests.first)
    #expect(request.path == path)
    #expect(request.bodyText == body)
}

@Test func seedanceEditWithoutTheClipFailsBeforeSending() async {
    let server = StubServer()
    var edit = seedance(hasSource: true)
    edit.mode = .edit

    await #expect(
        throws: ProviderError.validation(field: "video_url", message: "Seedance needs the clip to edit or extend.")
    ) {
        try await server.makeAPIProvider().submit(
            edit, inputs: RemoteInputs(video: nil, images: []), idempotencyKey: UUID())
    }
    #expect(server.requests.isEmpty)
}

@Test func otherModelsHaveAListPriceBeforeUpload() async throws {
    let provider = StubServer().makeAPIProvider()
    var kling = spec()
    kling.model = .klingMotionControl

    #expect(try await provider.estimate(kling) == .usd(Decimal(string: "1.512") ?? 0, isEstimate: true))
    #expect(
        try await provider.estimate(seedance(hasSource: false))
            == .usd(Decimal(string: "3.6976") ?? 0, isEstimate: true))
}

/// A job with nothing to upload is quoted by `POST /estimate` with the body its submit sends, before anything else
/// happens (issue #113); jobs that differ only in the prompt share the quote.
@Test func aJobWithoutMediaIsQuotedBeforeUpload() async throws {
    let server = StubServer()
    server.on(
        "POST", "/estimate/bytedance/seedance-2.5/text-to-video",
        StubResponse(body: #"{"credits": "59.000", "usd": "3.69"}"#))
    let provider = server.makeAPIProvider()
    let quote = Cost.usd(Decimal(string: "3.69") ?? 0, isEstimate: false)
    var reworded = seedance(hasSource: false)
    reworded.prompt = "a fox in the rain"

    #expect(try await provider.estimate(seedance(hasSource: false)) == quote)
    #expect(try await provider.estimate(reworded) == quote)

    #expect(server.requests.map(\.path) == ["/estimate/bytedance/seedance-2.5/text-to-video"])
    #expect(
        server.requests.first?.bodyText
            == #"{"aspect_ratio":"9:16","duration":8,"generate_audio":true,"prompt":"a fox in the snow","resolution":"720p"}"#
    )
}

/// A failed quote leaves the list price, and isn't kept: the next estimate asks again. A job with media, or without
/// the prompt its request needs, isn't quoted before upload.
@Test func withoutAQuoteTheListPriceStands() async throws {
    let server = StubServer()
    server.on("POST", "/estimate/bytedance/seedance-2.5/text-to-video", StubResponse(status: 503, body: "{}"))
    let provider = server.makeAPIProvider()
    let listPrice = Cost.usd(Decimal(string: "3.6976") ?? 0, isEstimate: true)
    var unprompted = seedance(hasSource: false)
    unprompted.prompt = " "

    #expect(try await provider.estimate(seedance(hasSource: false)) == listPrice)
    #expect(try await provider.estimate(seedance(hasSource: false)) == listPrice)
    #expect(try await provider.estimate(unprompted) == listPrice)
    #expect(try await provider.estimate(seedance(hasSource: false, references: 1)) == listPrice)
    #expect(server.requests.count == 2)
}
