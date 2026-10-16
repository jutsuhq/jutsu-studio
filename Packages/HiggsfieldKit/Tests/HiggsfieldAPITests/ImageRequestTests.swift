import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldAPI

private let input = URL(string: "https://cdn.example.com/a.jpg")!

/// Bodies as the model pages at docs.higgsfield.ai/docs/models document them (issue #42).
@Test(arguments: [
    (
        ModelEndpoint.soulV2,
        SoulImageRequest(prompt: "a knight", aspectRatio: "9:16", batchSize: 4)
            as any Encodable
            & Sendable, "/higgsfield-ai/soul/v2/standard",
        #"{"aspect_ratio":"9:16","batch_size":4,"prompt":"a knight"}"#
    ),
    (
        .grokImage2, GrokImageRequest(prompt: "a knight", aspectRatio: "1:1"), "/xai/grok-imagine-image-2.0",
        #"{"aspect_ratio":"1:1","prompt":"a knight"}"#
    ),
    (
        .grokImage2, GrokImageRequest(prompt: "add a cape", aspectRatio: "auto", imageURLs: [input]),
        "/xai/grok-imagine-image-2.0",
        #"{"aspect_ratio":"auto","image_urls":["https://cdn.example.com/a.jpg"],"prompt":"add a cape"}"#
    ),
    (
        .qwenImage3Edit, QwenEditRequest(prompt: "add a cape", imageURLs: [input], aspectRatio: "16:9"),
        "/alibaba/qwen-image-3/edit",
        #"{"aspect_ratio":"16:9","image_urls":["https://cdn.example.com/a.jpg"],"prompt":"add a cape"}"#
    ),
])
func imageSubmitSendsDocumentedBody(
    endpoint: ModelEndpoint, body: any Encodable & Sendable, path: String, expected: String
) async throws {
    let server = StubServer()
    server.on("POST", path, StubResponse(body: Fixture.submitted))
    server.on("POST", "/estimate\(path)", StubResponse(body: #"{"usd": "0.0128", "credits": "0.2"}"#))
    let client = server.makeClient()

    #expect(try await client.estimate(endpoint, body) == Decimal(string: "0.0128"))
    let job = try await client.submit(endpoint, body, idempotencyKey: UUID())

    #expect(job.requestID == "req-123")
    #expect(server.requests.map(\.bodyText) == [expected, expected])
}

@Test(arguments: [
    (Fixture.status("queued"), ImageStatus.queued),
    (Fixture.status("in_progress"), .inProgress),
    (
        Fixture.status(
            "completed",
            extra: #", "images": [{"url": "https://cdn.example.com/1.png"}, {"url": "https://cdn.example.com/2.png"}]"#
        ),
        .completed(imageURLs: [
            URL(string: "https://cdn.example.com/1.png")!, URL(string: "https://cdn.example.com/2.png")!,
        ])
    ),
    (
        Fixture.status("completed", extra: #", "images": [{"url": "http://cdn.example.com/1.png"}]"#),
        .failed(message: "Completed without an image URL.")
    ),
    (Fixture.status("completed"), .failed(message: "Completed without an image URL.")),
    (Fixture.status("failed", extra: #", "error": "bad prompt""#), .failed(message: "bad prompt")),
    (Fixture.status("nsfw"), .rejected(.explicitContent)),
    (Fixture.status("canceled"), .canceled),
])
func imageStatusReadsTheImages(body: String, expected: ImageStatus) async throws {
    let server = StubServer()
    server.on("GET", "/requests/req-123/status", StubResponse(body: body))
    #expect(try await server.makeClient().imageStatus(requestID: "req-123") == expected)
}
