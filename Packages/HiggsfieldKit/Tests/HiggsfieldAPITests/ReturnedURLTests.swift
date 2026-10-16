import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldAPI

@Test func estimateSendsTheSubmitBodyAndReadsTheUSDString() async throws {
    let server = StubServer()
    let path = "/estimate/higgsfield/genjutsu/motion-transfer/v1.0"
    server.on("POST", path, StubResponse(body: #"{"credits": "61.000", "usd": "3.816"}"#))

    let price = try await server.makeClient().estimate(.motionTransfer, Fixture.request())

    #expect(price == Decimal(string: "3.816")!)
    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.header("Authorization") == "Key key-id:key-secret")
    #expect(request.header("Idempotency-Key") == nil)
    let images = #"["https://cdn.example.com/a.jpg","https://cdn.example.com/b.png"]"#
    #expect(
        request.bodyText
            == #"{"image_urls":\#(images),"prompt":"","resolution":"480p","video_url":"https://cdn.example.com/in.mp4"}"#
    )
}

@Test func unreadableEstimateIsAServerError() async {
    let server = StubServer()
    server.on("POST", "/estimate/higgsfield/genjutsu/motion-transfer/v1.0", StubResponse(body: #"{"usd": "n/a"}"#))

    await #expect(throws: HiggsfieldError.server(status: 200)) {
        try await server.makeClient().estimate(.motionTransfer, Fixture.request())
    }
}

private let submitAnswers: [(String, GenerationStatus?)] = [
    (Fixture.status("queued"), .queued),
    (Fixture.status("in_progress"), .inProgress),
    (
        Fixture.status("completed", extra: #", "video": {"url": "https://cdn.example.com/out.mp4"}"#),
        .completed(videoURL: URL(string: "https://cdn.example.com/out.mp4")!)
    ),
    (Fixture.status("completed"), nil),
    (Fixture.status("failed", extra: #", "error": "Bad input""#), .failed(message: "Bad input")),
    (Fixture.status("nsfw"), .rejected(.explicitContent)),
    (Fixture.status("canceled"), .canceled),
    (#"{"request_id": "req-123"}"#, nil),
]

@Test(arguments: submitAnswers)
func submitStatusMapsLikeAPoll(body: String, expected: GenerationStatus?) async throws {
    let server = StubServer()
    server.on("POST", "/higgsfield/genjutsu/motion-transfer/v1.0", StubResponse(body: body))

    let job = try await server.makeClient().submit(.motionTransfer, Fixture.request(), idempotencyKey: UUID())

    #expect(job.initialStatus == expected)
}

@Test func returnedURLsOnTheAPIHostAreUsedForStatusAndCancel() async throws {
    let server = StubServer()
    server.on("GET", "/v2/requests/req-9/status", StubResponse(body: Fixture.status("queued")))
    server.on("POST", "/v2/requests/req-9/cancel", StubResponse(status: 202))
    let statusURL = server.baseURL.appendingPathComponent("v2/requests/req-9/status")
    let cancelURL = server.baseURL.appendingPathComponent("v2/requests/req-9/cancel")
    let client = server.makeClient()

    #expect(try await client.status(requestID: "req-9", statusURL: statusURL) == .queued)
    try await client.cancel(requestID: "req-9", cancelURL: cancelURL)

    #expect(server.requests.map(\.path) == ["/v2/requests/req-9/status", "/v2/requests/req-9/cancel"])
    #expect(server.requests.allSatisfy { $0.header("Authorization") == "Key key-id:key-secret" })
}

@Test func returnedURLsElsewhereNeverGetTheKey() async throws {
    let server = StubServer()
    let elsewhere = StubServer()
    server.on("GET", "/requests/req-9/status", StubResponse(body: Fixture.status("queued")))
    server.on("POST", "/requests/req-9/cancel", StubResponse(status: 202))
    let statusURL = elsewhere.baseURL.appendingPathComponent("requests/req-9/status")
    let cancelURL = elsewhere.baseURL.appendingPathComponent("requests/req-9/cancel")
    let client = server.makeClient()

    #expect(try await client.status(requestID: "req-9", statusURL: statusURL) == .queued)
    try await client.cancel(requestID: "req-9", cancelURL: cancelURL)

    #expect(elsewhere.requests.isEmpty)
    #expect(server.requests.map(\.path) == ["/requests/req-9/status", "/requests/req-9/cancel"])
}

private let untrustedURLs = [
    "http://api.higgsfield.ai/requests/r/status",
    "https://api.higgsfield.ai.evil.example/requests/r/status",
    "https://evil.example/requests/r/status",
    "https://api.higgsfield.ai:8443/requests/r/status",
    "ftp://api.higgsfield.ai/requests/r/status",
]

@Test(arguments: untrustedURLs)
func onlyHTTPSOnTheAPIHostIsTrusted(returned: String) {
    let client = HiggsfieldAPIClient(keyID: "k", secret: "s")
    let fallback = HiggsfieldAPIClient.defaultBaseURL.appendingPathComponent("requests/r/status")

    #expect(client.trustedURL(URL(string: returned), orPath: "requests/r/status") == fallback)
}

@Test func trustedURLKeepsTheAPIHostInAnyCaseAndFallsBackWhenMissing() throws {
    let client = HiggsfieldAPIClient(keyID: "k", secret: "s")
    let returned = try #require(URL(string: "https://API.higgsfield.ai/v2/requests/r/status"))

    #expect(client.trustedURL(returned, orPath: "requests/r/status") == returned)
    #expect(
        client.trustedURL(nil, orPath: "requests/r/status")
            == HiggsfieldAPIClient.defaultBaseURL.appendingPathComponent("requests/r/status"))
}
