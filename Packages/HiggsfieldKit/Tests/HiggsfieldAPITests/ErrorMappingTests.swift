import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldAPI

private let validationDetail = """
    {"detail": [
      {"type": "too_short", "loc": ["body", "image_urls"], "msg": "List should have at least 1 item"},
      {"type": "string_type", "loc": ["body", "prompt"], "msg": "Input should be a valid string"}
    ]}
    """

@Test(arguments: [
    (401, #"{"detail": "Invalid credentials"}"#, HiggsfieldError.unauthorized),
    (403, #"{"detail": "Not enough credits"}"#, .insufficientFunds),
    (400, #"{"detail": "Maximum number of concurrent requests (10) reached"}"#, .concurrencyLimit(max: 10)),
    (400, "Maximum number of concurrent requests (2)", .concurrencyLimit(max: 2)),
    (400, #"{"detail": "Maximum number of concurrent requests reached"}"#, .concurrencyLimit(max: nil)),
    (
        400, #"{"detail": "Request is already in progress"}"#,
        .validation(field: nil, message: "Request is already in progress")
    ),
    (
        422, validationDetail,
        .validation(
            field: "image_urls", message: "List should have at least 1 item; Input should be a valid string")
    ),
    (
        422, #"{"detail": [{"loc": ["image_urls", 0], "msg": "Invalid URL"}]}"#,
        .validation(field: "image_urls", message: "Invalid URL")
    ),
    (
        422, #"{"detail": "Idempotency key reused with a different body"}"#,
        .validation(field: nil, message: "Idempotency key reused with a different body")
    ),
    (
        422, Fixture.seedanceWithoutReferences,
        .validation(
            field: nil,
            message: "Provide at least one nonempty reference array: image_urls, video_urls or audio_urls")
    ),
    (400, "", .validation(field: nil, message: "The request was rejected.")),
    (423, "", .modelUnavailable),
    (503, "Service Unavailable", .modelUnavailable),
    (500, "", .server(status: 500)),
    (502, "", .server(status: 502)),
    (404, #"{"detail": "Not found"}"#, .validation(field: nil, message: "Not found")),
])
func httpErrorsMapToHiggsfieldErrors(status: Int, body: String, expected: HiggsfieldError) {
    #expect(HiggsfieldAPIErrors.error(status: status, body: Data(body.utf8)) == expected)
}

@Test(arguments: [200, 202, 204])
func successIsNotAnError(status: Int) {
    #expect(HiggsfieldAPIErrors.error(status: status, body: Data()) == nil)
}

@Test func clientThrowsMappedErrorForConcurrencyLimit() async {
    let server = StubServer()
    server.on(
        "POST", "/" + ModelEndpoint.motionTransfer.rawValue,
        StubResponse(
            status: 400, headers: ["X-Correlation-ID": "corr-9"],
            body: #"{"detail": "Maximum number of concurrent requests (2)"}"#))

    await #expect(throws: HiggsfieldError.concurrencyLimit(max: 2)) {
        try await server.makeClient().submit(.motionTransfer, Fixture.request(), idempotencyKey: UUID())
    }
}

@Test func transportFailureIsNetworkError() async {
    let server = StubServer()
    server.on("GET", "/requests/req-123/status", fail: URLError(.notConnectedToInternet))

    await #expect(throws: HiggsfieldError.network) {
        try await server.makeClient().status(requestID: "req-123")
    }
}

@Test func unreadableSuccessBodyIsServerError() async {
    let server = StubServer()
    server.on("GET", "/requests/req-123/status", StubResponse(body: "<html>"))

    await #expect(throws: HiggsfieldError.server(status: 200)) {
        try await server.makeClient().status(requestID: "req-123")
    }
}

@Test func validateKeyAcceptsWorkingKey() async throws {
    let server = StubServer()
    server.on("GET", "/models/higgsfield/genjutsu/restyle/v1.0/presets", StubResponse(body: Fixture.presets))
    #expect(try await server.makeClient().validateKey())
}

@Test func validateKeyRejectsRefusedKey() async throws {
    let server = StubServer()
    server.on("GET", "/models/higgsfield/genjutsu/restyle/v1.0/presets", StubResponse(status: 401))
    #expect(try await server.makeClient().validateKey() == false)
}

@Test func validateKeyThrowsWhenOffline() async {
    let server = StubServer()
    server.on("GET", "/models/higgsfield/genjutsu/restyle/v1.0/presets", fail: URLError(.timedOut))
    await #expect(throws: HiggsfieldError.network) {
        try await server.makeClient().validateKey()
    }
}
