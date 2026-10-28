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

private let queueFull = """
    {"detail": {"code": "account_queue_full", "message": "Too many queued generations for this account",
      "retryable": true, "limit": 40, "retry_after_seconds": 30}}
    """

private let admissionUnavailable = """
    {"detail": {"code": "admission_control_unavailable", "message": "Queue admission is unavailable", "retryable": true}}
    """

@Test(arguments: [
    (401, #"{"detail": "Invalid credentials"}"#, HiggsfieldError.unauthorized),
    (403, #"{"detail": "Not enough credits"}"#, .insufficientFunds),
    (
        400, #"{"detail": "Maximum number of concurrent requests (2) has been reached"}"#,
        .validation(field: nil, message: "Maximum number of concurrent requests (2) has been reached")
    ),
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
    (503, #"{"detail": "Model is disabled"}"#, .modelUnavailable),
    (503, admissionUnavailable, .server(status: 503)),
    (
        503, #"{"code": "admission_control_unavailable", "detail": "Queue admission is unavailable"}"#,
        .server(status: 503)
    ),
    (429, queueFull, .concurrencyLimit(retryAfter: 30)),
    (
        429, #"{"detail": "Maximum number of concurrent requests (2) has been reached"}"#,
        .concurrencyLimit(retryAfter: nil)
    ),
    (429, "", .concurrencyLimit(retryAfter: nil)),
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

@Test func anObjectDetailGivesItsMessage() {
    #expect(
        HiggsfieldAPIErrors.detail(of: Data(queueFull.utf8)).message == "Too many queued generations for this account")
    #expect(
        HiggsfieldAPIErrors.detail(of: Data(#"{"detail": {"code": "x"}}"#.utf8)).message
            == #"{"detail": {"code": "x"}}"#)
}

/// `Retry-After` is the wait; the body's `retry_after_seconds` (30) stands in when the header is missing or unreadable.
@Test(
    arguments: [
        ("45", 45.0), (" 7 ", 7), (nil, 30), ("soon", 30), ("-1", 30), ("Wed, 21 Oct 2026 07:28:00 GMT", 30),
    ] as [(String?, TimeInterval)])
func aFullQueueWaitsAsTheServerAsks(header: String?, wait: TimeInterval) {
    #expect(
        HiggsfieldAPIErrors.error(status: 429, body: Data(queueFull.utf8), retryAfter: header)
            == .concurrencyLimit(retryAfter: wait))
}

@Test func aRetryAfterHeaderAloneIsTheWait() {
    #expect(HiggsfieldAPIErrors.error(status: 429, body: Data(), retryAfter: "12") == .concurrencyLimit(retryAfter: 12))
}

@Test func clientReadsRetryAfterOfAFullQueue() async {
    let server = StubServer()
    server.on(
        "POST", "/" + ModelEndpoint.motionTransfer.rawValue,
        StubResponse.json(queueFull, status: 429, headers: ["Retry-After": "20", "X-Correlation-ID": "corr-9"]))

    await #expect(throws: HiggsfieldError.concurrencyLimit(retryAfter: 20)) {
        try await server.makeClient().submit(.motionTransfer, Fixture.request(), idempotencyKey: UUID())
    }
}

/// A full queue creates nothing, so the submit sent again after the wait carries the same key and can't charge twice.
@Test func aSubmitSentAgainAfterAFullQueueKeepsItsIdempotencyKey() async throws {
    let server = StubServer { _, earlier in
        earlier == 0
            ? StubResponse.json(queueFull, status: 429, headers: ["Retry-After": "1"])
            : StubResponse.json(#"{"status": "queued", "request_id": "req-1"}"#)
    }
    let client = server.makeClient()
    let key = UUID()

    await #expect(throws: HiggsfieldError.concurrencyLimit(retryAfter: 1)) {
        try await client.submit(.motionTransfer, Fixture.request(), idempotencyKey: key)
    }
    #expect(try await client.submit(.motionTransfer, Fixture.request(), idempotencyKey: key).requestID == "req-1")
    let keys = server.requests.map { $0.header("Idempotency-Key") }
    #expect(keys == [key.uuidString.lowercased(), key.uuidString.lowercased()])
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
