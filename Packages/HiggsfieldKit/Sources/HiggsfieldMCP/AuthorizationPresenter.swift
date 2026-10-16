import Foundation

/// The browser step of the authorization code flow: decides where the redirect arrives, opens the
/// authorization URL built for that redirect URI and returns the redirect. Throws `CancellationError` when
/// the task is cancelled.
public protocol AuthorizationPresenter: Sendable {
    func authorize(makeURL: @Sendable (_ redirectURI: String) throws -> URL) async throws -> AuthorizationRedirect
}

public struct AuthorizationRedirect: Sendable, Hashable {
    /// The full redirect, with `code` or `error` and `state` in its query.
    public let callback: URL
    /// The redirect URI the authorization URL was built with; the token request has to repeat it.
    public let redirectURI: String

    public init(callback: URL, redirectURI: String) {
        self.callback = callback
        self.redirectURI = redirectURI
    }
}
