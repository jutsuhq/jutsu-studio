import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldAPI

private let images = #"["https://cdn.example.com/a.jpg","https://cdn.example.com/b.png"]"#
private let video = #""https://cdn.example.com/in.mp4""#

@Test(arguments: [
    (
        ModelEndpoint.motionTransfer, Fixture.request(), "/higgsfield/genjutsu/motion-transfer/v1.0",
        #"{"image_urls":\#(images),"prompt":"","resolution":"480p","video_url":\#(video)}"#
    ),
    (
        .objectSwap, Fixture.request(prompt: "a red car", resolution: "1080p"),
        "/higgsfield/genjutsu/object-swap/v1.0",
        #"{"image_urls":\#(images),"prompt":"a red car","resolution":"1080p","video_url":\#(video)}"#
    ),
    (
        .restyle, Fixture.request(resolution: "720p", presetID: Fixture.presetID),
        "/higgsfield/genjutsu/restyle/v1.0",
        #"{"image_urls":\#(images),"preset_id":"c2143317-f28d-4c3c-a0b8-39bd547e08a7","prompt":"","resolution":"720p","video_url":\#(video)}"#
    ),
])
func submitSendsDocumentedRequest(
    endpoint: ModelEndpoint, generation: GenerationRequest, path: String, body: String
) async throws {
    let server = StubServer()
    server.on("POST", path, StubResponse(headers: ["X-Correlation-ID": "corr-1"], body: Fixture.submitted))
    let key = UUID()

    let job = try await server.makeClient().submit(endpoint, generation, idempotencyKey: key)

    #expect(
        job
            == SubmittedRequest(
                requestID: "req-123", correlationID: "corr-1",
                statusURL: URL(string: "https://api.higgsfield.ai/requests/req-123/status"),
                cancelURL: URL(string: "https://api.higgsfield.ai/requests/req-123/cancel"), initialStatus: .queued))
    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.path == path)
    #expect(request.header("Authorization") == "Key key-id:key-secret")
    #expect(request.header("Idempotency-Key") == key.uuidString.lowercased())
    #expect(request.header("Content-Type") == "application/json")
    #expect(request.bodyText == body)
    #expect(request.bodyText?.contains("null") == false)
}

private let source = URL(string: "https://cdn.example.com/in.mp4")!
private let character = URL(string: "https://cdn.example.com/a.jpg")!

@Test(arguments: [
    (
        ModelEndpoint.seedanceTextToVideo,
        SeedanceRequest(
            prompt: "a fox in the snow", duration: 8, resolution: "720p", aspectRatio: "9:16", generateAudio: true),
        "/bytedance/seedance-2.5/text-to-video",
        #"{"aspect_ratio":"9:16","duration":8,"generate_audio":true,"prompt":"a fox in the snow","resolution":"720p"}"#
    ),
    (
        .seedanceReferenceToVideo,
        SeedanceRequest(
            prompt: "", imageURLs: [character], videoURLs: [source], duration: 12, resolution: "480p",
            aspectRatio: "16:9", generateAudio: false),
        "/bytedance/seedance-2.5/reference-to-video",
        #"{"aspect_ratio":"16:9","duration":12,"generate_audio":false,"image_urls":["https://cdn.example.com/a.jpg"],"resolution":"480p","video_urls":["https://cdn.example.com/in.mp4"]}"#
    ),
    (
        .seedanceReferenceToVideo,
        SeedanceRequest(prompt: "dance", imageURLs: [character], duration: 5, resolution: "1080p", generateAudio: true),
        "/bytedance/seedance-2.5/reference-to-video",
        #"{"duration":5,"generate_audio":true,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"dance","resolution":"1080p"}"#
    ),
    (
        .seedanceReferenceToVideo,
        SeedanceRequest(
            prompt: "", videoURLs: [source], duration: 6, resolution: "720p", generateAudio: true,
            bitrateMode: "standard"),
        "/bytedance/seedance-2.5/reference-to-video",
        #"{"bitrate_mode":"standard","duration":6,"generate_audio":true,"resolution":"720p","video_urls":["https://cdn.example.com/in.mp4"]}"#
    ),
])
func seedanceSendsOnlyTheFieldsItHas(
    endpoint: ModelEndpoint, generation: SeedanceRequest, path: String, body: String
) async throws {
    let server = StubServer()
    server.on("POST", path, StubResponse(body: Fixture.submitted))

    _ = try await server.makeClient().submit(endpoint, generation, idempotencyKey: UUID())

    let request = try #require(server.requests.first)
    #expect(request.path == path)
    #expect(request.bodyText == body)
    #expect(request.bodyText?.contains("null") == false)
}

@Test(arguments: [
    (
        ModelEndpoint.seedanceVideoEdit,
        SeedanceVideoRequest(prompt: "make it night", videoURL: source, resolution: "720p", generateAudio: false),
        "/bytedance/seedance-2.5/video-edit",
        #"{"generate_audio":false,"prompt":"make it night","resolution":"720p","video_url":"https://cdn.example.com/in.mp4"}"#
    ),
    (
        .seedanceVideoExtend,
        SeedanceVideoRequest(
            prompt: "she turns around", videoURL: source, imageURLs: [character], duration: 6, resolution: "1080p",
            generateAudio: true),
        "/bytedance/seedance-2.5/video-extend",
        #"{"duration":6,"generate_audio":true,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"she turns around","resolution":"1080p","video_url":"https://cdn.example.com/in.mp4"}"#
    ),
])
func seedanceEditAndExtendSendTheSourceAndOnlyTheFieldsTheyHave(
    endpoint: ModelEndpoint, generation: SeedanceVideoRequest, path: String, body: String
) async throws {
    let server = StubServer()
    server.on("POST", path, StubResponse(body: Fixture.submitted))

    _ = try await server.makeClient().submit(endpoint, generation, idempotencyKey: UUID())

    let request = try #require(server.requests.first)
    #expect(request.path == path)
    #expect(request.bodyText == body)
    #expect(request.bodyText?.contains("null") == false)
}

@Test(arguments: [
    (ModelEndpoint.klingMotionControlStandard, "/kling-video/v3/motion-control/std", ""),
    (.klingMotionControlPro, "/kling-video/v3/motion-control/pro", "walks to the door"),
])
func klingSendsTheCharacterAndTheMotion(endpoint: ModelEndpoint, path: String, prompt: String) async throws {
    let server = StubServer()
    server.on("POST", path, StubResponse(body: Fixture.submitted))
    server.on("POST", "/estimate" + path, StubResponse(body: #"{"usd": "1.512"}"#))
    let client = server.makeClient()
    let generation = KlingMotionRequest(imageURL: character, videoURL: source, prompt: prompt)

    #expect(try await client.estimate(endpoint, generation) == Decimal(string: "1.512"))
    _ = try await client.submit(endpoint, generation, idempotencyKey: UUID())

    let promptField = prompt.isEmpty ? "" : #","prompt":"\#(prompt)""#
    let body =
        #"{"image_url":"https://cdn.example.com/a.jpg"\#(promptField),"video_url":"https://cdn.example.com/in.mp4"}"#
    #expect(server.requests.map(\.path) == ["/estimate" + path, path])
    #expect(server.requests.allSatisfy { $0.bodyText == body })
}

@Test func klingSendsTheSoundAndOrientationAsTheSchemaSpellsThem() async throws {
    let server = StubServer()
    let path = "/kling-video/v3/motion-control/std"
    server.on("POST", path, StubResponse(body: Fixture.submitted))
    let generation = KlingMotionRequest(
        imageURL: character, videoURL: source, prompt: "", keepOriginalSound: .drop, characterOrientation: .image)

    _ = try await server.makeClient().submit(.klingMotionControlStandard, generation, idempotencyKey: UUID())

    #expect(
        server.requests.first?.bodyText
            == #"{"character_orientation":"image","image_url":"https://cdn.example.com/a.jpg","keep_original_sound":"no","video_url":"https://cdn.example.com/in.mp4"}"#
    )
}

/// The source is the one `video_urls` item and the quality the `mode`; without images, `image_urls` is left out.
@Test(arguments: [
    (
        KlingVideoReferenceRequest(prompt: "she spins", videoURL: source, quality: .standard, duration: 5),
        #"{"duration":5,"mode":"std","prompt":"she spins","video_urls":["https://cdn.example.com/in.mp4"]}"#
    ),
    (
        KlingVideoReferenceRequest(
            prompt: "she spins", videoURL: source, imageURLs: [character], quality: .pro, duration: 10),
        #"{"duration":10,"image_urls":["https://cdn.example.com/a.jpg"],"mode":"pro","prompt":"she spins","video_urls":["https://cdn.example.com/in.mp4"]}"#
    ),
])
func klingO3SendsTheReferenceVideoAndTheQuality(generation: KlingVideoReferenceRequest, body: String) async throws {
    let server = StubServer()
    let path = "/kling-video/o3/video-reference"
    server.on("POST", path, StubResponse(body: Fixture.submitted))

    _ = try await server.makeClient().submit(.klingO3VideoReference, generation, idempotencyKey: UUID())

    #expect(server.requests.first?.path == path)
    #expect(server.requests.first?.bodyText == body)
}

/// Cinema Studio's creative controls go in as top-level fields beside the others; MiniMax H3 sends its "2K" and no
/// frame, soundtrack or controls.
@Test(arguments: [
    (
        ModelEndpoint.cinemaStudio4, "/higgsfield/cinema-studio/4.0",
        ReferenceToVideoRequest(
            prompt: "rain", videoURL: source, duration: 6, resolution: "480p", aspectRatio: "21:9",
            generateAudio: true, controls: ["genre": "noir", "camera_movement": "whip-pan"]),
        #"{"aspect_ratio":"21:9","camera_movement":"whip-pan","duration":6,"generate_audio":true,"genre":"noir","prompt":"rain","resolution":"480p","video_urls":["https://cdn.example.com/in.mp4"]}"#
    ),
    (
        .minimaxH3ReferenceToVideo, "/minimax/h3/reference-to-video",
        ReferenceToVideoRequest(
            prompt: "rain", videoURL: source, imageURLs: [character], duration: 15, resolution: "2K"),
        #"{"duration":15,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"rain","resolution":"2K","video_urls":["https://cdn.example.com/in.mp4"]}"#
    ),
])
func referenceToVideoSendsOnlyTheFieldsItHas(
    endpoint: ModelEndpoint, path: String, generation: ReferenceToVideoRequest, body: String
) async throws {
    let server = StubServer()
    server.on("POST", path, StubResponse(body: Fixture.submitted))

    _ = try await server.makeClient().submit(endpoint, generation, idempotencyKey: UUID())

    let request = try #require(server.requests.first)
    #expect(request.path == path)
    #expect(request.bodyText == body)
}

/// The start frame is `image_url`; without an end frame, an empty prompt or a bitrate, those keys are left out.
@Test(arguments: [
    (
        SeedanceFramesRequest(
            prompt: "", imageURL: character, duration: 5, resolution: "720p", generateAudio: true),
        #"{"duration":5,"generate_audio":true,"image_url":"https://cdn.example.com/a.jpg","resolution":"720p"}"#
    ),
    (
        SeedanceFramesRequest(
            prompt: "she turns", imageURL: character, endImageURL: URL(string: "https://cdn.example.com/b.jpg"),
            duration: 8, resolution: "1080p", generateAudio: false, bitrateMode: "high"),
        #"{"bitrate_mode":"high","duration":8,"end_image_url":"https://cdn.example.com/b.jpg","generate_audio":false,"image_url":"https://cdn.example.com/a.jpg","prompt":"she turns","resolution":"1080p"}"#
    ),
])
func seedanceFramesGoToImageToVideo(generation: SeedanceFramesRequest, body: String) async throws {
    let server = StubServer()
    let path = "/bytedance/seedance-2.5/image-to-video"
    server.on("POST", path, StubResponse(body: Fixture.submitted))

    _ = try await server.makeClient().submit(.seedanceImageToVideo, generation, idempotencyKey: UUID())

    let request = try #require(server.requests.first)
    #expect(request.path == path)
    #expect(request.bodyText == body)
}

@Test func restyleWithoutReferencesSendsEmptyArray() async throws {
    let server = StubServer()
    server.on("POST", "/higgsfield/genjutsu/restyle/v1.0", StubResponse(body: Fixture.submitted))
    var generation = Fixture.request(presetID: Fixture.presetID)
    generation.imageURLs = []

    let job = try await server.makeClient().submit(.restyle, generation, idempotencyKey: UUID())

    #expect(job.correlationID == nil)
    let body = try #require(server.requests.first?.bodyText)
    #expect(body.contains(#""image_urls":[]"#))
    #expect(body.contains(#""prompt":"""#))
}

@Test func statusAndCancelUseRequestPaths() async throws {
    let server = StubServer()
    server.on("GET", "/requests/req-123/status", StubResponse(body: Fixture.status("queued")))
    server.on("POST", "/requests/req-123/cancel", StubResponse(status: 202))
    let client = server.makeClient()

    #expect(try await client.status(requestID: "req-123") == .queued)
    try await client.cancel(requestID: "req-123")

    let requests = server.requests
    #expect(requests.map(\.method) == ["GET", "POST"])
    #expect(requests.allSatisfy { $0.header("Authorization") == "Key key-id:key-secret" })
}

@Test func uploadPutsFileWithoutAuthorization() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("fake video".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let server = StubServer()
    let uploadURL = "\(server.baseURL.absoluteString)/bucket/in.mp4?X-Signature=abc"
    server.on(
        "POST", "/files/generate-upload-url",
        StubResponse(
            body: #"""
                {"upload_url": "\#(uploadURL)", "public_url": "https://cdn.example.com/in.mp4",
                 "content_type": "video/mp4",
                 "upload_headers": {"Content-Type": "video/mp4", "x-amz-tagging": "retention=temporary"}}
                """#))
    server.on("PUT", "/bucket/in.mp4", StubResponse())
    let client = server.makeClient()

    let target = try await client.uploadTarget(contentType: "video/mp4")
    try await client.put(
        fileAt: file, contentType: "video/mp4", to: target.uploadURL, headers: target.uploadHeaders ?? [:])

    #expect(target.publicURL == URL(string: "https://cdn.example.com/in.mp4")!)
    let requests = server.requests
    try #require(requests.count == 2)
    #expect(requests[0].method == "POST")
    #expect(requests[0].header("Authorization") == "Key key-id:key-secret")
    #expect(requests[0].bodyText == #"{"content_type":"video/mp4"}"#)
    #expect(requests[1].method == "PUT")
    #expect(requests[1].url.absoluteString == uploadURL)
    #expect(requests[1].header("Authorization") == nil)
    #expect(requests[1].header("Content-Type") == "video/mp4")
    #expect(requests[1].header("x-amz-tagging") == "retention=temporary")
}

@Test func storageRefusalIsNotAKeyOrBalanceError() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("fake video".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let server = StubServer()
    server.on("PUT", "/bucket/in.mp4", StubResponse(status: 403, body: "<Error>Request has expired</Error>"))

    await #expect(throws: HiggsfieldError.server(status: 403)) {
        try await server.makeClient().put(
            fileAt: file, contentType: "video/mp4", to: server.baseURL.appendingPathComponent("bucket/in.mp4"))
    }
}

@Test func uploadURLThatIsNotHTTPSIsNeverOpened() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("fake video".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let server = StubServer()
    server.on("PUT", "/bucket/in.mp4", StubResponse())
    for text in ["http://\(server.host)/bucket/in.mp4", "file:///tmp/in.mp4"] {
        let url = try #require(URL(string: text))
        await #expect(throws: HiggsfieldError.server(status: 200)) {
            try await server.makeClient().put(fileAt: file, contentType: "video/mp4", to: url)
        }
    }
    #expect(server.requests.isEmpty)
}

@Test func presetsDecodeDocumentedCatalog() async throws {
    let server = StubServer()
    server.on("GET", "/models/higgsfield/genjutsu/restyle/v1.0/presets", StubResponse(body: Fixture.presets))

    let presets = try await server.makeClient().presets()

    #expect(
        presets == [
            Preset(
                id: Fixture.presetID, name: "Cel-Shaded CG Anime",
                previewURL: URL(
                    string:
                        "https://cdn.higgsfield.ai/restyle_presets/259d7ddb-4201-49f7-8a91-cee5bce28715.webp")!)
        ])
    #expect(server.requests.first?.header("Authorization") == "Key key-id:key-secret")
}
