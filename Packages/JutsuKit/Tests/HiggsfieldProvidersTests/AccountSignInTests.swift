import Foundation
import HiggsfieldMCP
import JutsuCore
import Testing

@testable import HiggsfieldProviders

@Test(arguments: [
    (OAuthError.discoveryFailed, SignInError.unavailable),
    (.unsupportedFlow, .flowUnavailable),
    (.registrationUnavailable, .flowUnavailable),
    (.redirectUnavailable, .flowUnavailable),
    (.stateMismatch, .invalidResponse),
    (.issuerMismatch, .invalidResponse),
    (.invalidCallback, .invalidResponse),
    (.accessDenied, .denied),
    (.timedOut, .timedOut),
    (.reauthenticationRequired, .reauthenticationRequired),
    (.server(code: "invalid_client", description: "Client not allowed"), .server("Client not allowed")),
    (.server(code: "invalid_client", description: nil), .server("invalid_client")),
])
func oauthFailuresBecomeSignInErrors(oauth: OAuthError, expected: SignInError) {
    #expect(AccountSignIn.error(for: oauth) as? SignInError == expected)
}

@Test func otherErrorsPassThrough() {
    #expect(AccountSignIn.error(for: CancellationError()) is CancellationError)
    #expect(AccountSignIn.error(for: ProviderError.network) as? ProviderError == .network)
}
