import Foundation

/// Sign-in failures in terms the user can act on.
public enum SignInError: Error, Sendable, Hashable {
    /// No authorization server could be read.
    case unavailable
    /// The server doesn't offer this flow, or won't register the app.
    case flowUnavailable
    case denied
    /// The browser didn't come back before the sign-in's deadline.
    case timedOut
    /// A redirect or token answer that doesn't check out (state, issuer, missing code).
    case invalidResponse
    /// The stored sign-in can't be refreshed any more.
    case reauthenticationRequired
    /// An OAuth error response; the description when the server sent one.
    case server(String?)
}
