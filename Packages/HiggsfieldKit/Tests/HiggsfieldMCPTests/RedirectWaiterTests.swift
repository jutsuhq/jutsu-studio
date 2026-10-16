import Foundation
import Testing

@testable import HiggsfieldMCP

@Suite(.timeLimit(.minutes(1))) struct RedirectWaiterTests {
    static func callback(state: String) throws -> URL {
        try #require(URL(string: "http://127.0.0.1:47613/callback?code=c&state=\(state)"))
    }

    @Test func callbackWithAnotherStateIsIgnoredAndWaitingGoesOn() async throws {
        let waiter = RedirectWaiter()
        waiter.expect(state: "right")
        let forged = try Self.callback(state: "forged")
        let genuine = try Self.callback(state: "right")
        let stateless = try #require(URL(string: "http://127.0.0.1:47613/callback"))

        #expect(!waiter.offer(forged))
        #expect(!waiter.offer(stateless))
        #expect(waiter.offer(genuine))

        let received = try await waiter.wait(timeout: .seconds(30))
        #expect(received == genuine)
    }

    @Test func callbacksBeforeTheRequestIsKnownAreIgnored() throws {
        let waiter = RedirectWaiter()
        let callback = try Self.callback(state: "right")
        #expect(!waiter.offer(callback))
    }

    @Test func missingRedirectFailsAfterTheDeadline() async {
        let waiter = RedirectWaiter()
        waiter.expect(state: "right")
        await #expect(throws: OAuthError.timedOut) {
            _ = try await waiter.wait(timeout: .milliseconds(50))
        }
    }

    @Test func forgedCallbackDoesNotEndTheWait() async throws {
        let waiter = RedirectWaiter()
        waiter.expect(state: "right")
        waiter.offer(try Self.callback(state: "forged"))
        await #expect(throws: OAuthError.timedOut) {
            _ = try await waiter.wait(timeout: .milliseconds(50))
        }
    }

    @Test func cancellingStopsWaiting() async {
        let waiter = RedirectWaiter()
        waiter.expect(state: "right")
        let waiting = Task { try await waiter.wait(timeout: .seconds(30)) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }
}
