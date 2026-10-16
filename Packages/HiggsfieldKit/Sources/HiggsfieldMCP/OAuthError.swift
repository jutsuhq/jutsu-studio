import Foundation

public enum OAuthError: Error, Sendable, Hashable {
    /// No protected resource or authorization server metadata could be read.
    case discoveryFailed
    /// None of the advertised authorization servers supports the requested flow.
    case unsupportedFlow
    /// The server neither accepts a client ID metadata document nor offers dynamic registration.
    case registrationUnavailable
    /// The callback's `state` differs from the one sent: a forged or stale redirect.
    case stateMismatch
    /// The callback's `iss` names another authorization server (RFC 9207 mix-up defense).
    case issuerMismatch
    case invalidCallback
    /// None of the loopback redirect ports could be opened, e.g. all taken by other apps.
    case redirectUnavailable
    case accessDenied
    /// The browser didn't come back with the redirect before the sign-in's deadline.
    case timedOut
    /// The refresh token is missing or was refused; the user has to sign in again.
    case reauthenticationRequired
    /// An OAuth error response (RFC 6749 §5.2).
    case server(code: String, description: String?)

    /// RFC 6749 §5.2 codes that refuse the grant or the client, so the stored tokens can never be refreshed.
    static let refusalCodes: Set<String> = ["invalid_grant", "invalid_client"]

    /// Whether this failure of a refresh means the user has to sign in again.
    var refusesRefresh: Bool {
        switch self {
        case .reauthenticationRequired: true
        case .server(let code, _): Self.refusalCodes.contains(code)
        default: false
        }
    }
}
