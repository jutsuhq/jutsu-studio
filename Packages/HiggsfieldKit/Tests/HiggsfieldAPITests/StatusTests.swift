import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldAPI

@Test(arguments: [
    (Fixture.status("queued"), GenerationStatus.queued),
    (Fixture.status("in_progress"), .inProgress),
    (
        Fixture.status("completed", extra: #", "video": {"url": "https://example.com/output.mp4"}"#),
        .completed(videoURL: URL(string: "https://example.com/output.mp4")!)
    ),
    (Fixture.status("completed"), .failed(message: "Completed without a video URL.")),
    (
        Fixture.status("failed", extra: #", "error": "Could not download video_url""#),
        .failed(message: "Could not download video_url")
    ),
    (Fixture.status("failed"), .failed(message: nil)),
    (Fixture.status("nsfw"), .rejected(.explicitContent)),
    (Fixture.status("canceled"), .canceled),
    (Fixture.status("upscaling"), .inProgress),
])
func statusMapsToGenerationStatus(body: String, expected: GenerationStatus) async throws {
    let server = StubServer()
    server.on("GET", "/requests/req-123/status", StubResponse(body: body))
    #expect(try await server.makeClient().status(requestID: "req-123") == expected)
}
