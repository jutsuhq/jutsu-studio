import Foundation
import HiggsfieldCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// This app as a public OAuth client of one authorization server, for one protected resource.
/// Owns the token endpoint; the authorizers build on it.
public struct OAuthClient: Sendable {
    public static let defaultScope = "openid email offline_access"

    public let server: AuthorizationServerMetadata
    public let clientID: String
    /// Sent as `resource` (RFC 8707) so tokens are bound to the MCP server.
    public let resource: URL
    public let scope: String
    let session: URLSession
    let now: @Sendable () -> Date

    public init(
        server: AuthorizationServerMetadata, clientID: String, resource: URL, scope: String = Self.defaultScope,
        session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.server = server
        self.clientID = clientID
        self.resource = resource
        self.scope = scope
        self.session = session
        self.now = now
    }

    /// Exchanges a refresh token. The server may omit a new refresh token; the old one then stays valid.
    /// Throws `OAuthError.reauthenticationRequired` only when the token endpoint refuses the grant (a 400 or 401,
    /// or an `invalid_grant` or `invalid_client` error); any other answer throws `HiggsfieldError.server`.
    public func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.reauthenticationRequired }
        let (data, response) = try await postTokenRequest([
            "grant_type": GrantType.refreshToken,
            "refresh_token": refreshToken,
            "resource": resource.absoluteString,
        ])
        guard response.isSuccess else { throw Self.refreshError(data, response) }
        var refreshed = try tokenSet(from: data, response)
        refreshed.refreshToken = refreshed.refreshToken ?? refreshToken
        refreshed.email = refreshed.email ?? tokens.email
        refreshed.name = refreshed.name ?? tokens.name
        refreshed.subject = refreshed.subject ?? tokens.subject
        return refreshed
    }

    /// Revokes the refresh token (RFC 7009), which also ends its access tokens at most servers. Without a
    /// refresh token, revokes the access token. Throws `OAuthError.unsupportedFlow` when the server has no
    /// revocation endpoint.
    public func revoke(_ tokens: TokenSet) async throws {
        guard let endpoint = server.revocationEndpoint else { throw OAuthError.unsupportedFlow }
        let (token, hint) = tokens.refreshToken.map { ($0, "refresh_token") } ?? (tokens.accessToken, "access_token")
        let (data, response) = try await session.postForm(
            endpoint, ["token": token, "token_type_hint": hint, "client_id": clientID])
        guard response.isSuccess else { throw oauthError(data, response) }
    }

    /// POSTs `parameters` plus `client_id` to the token endpoint.
    func requestTokens(_ parameters: [String: String]) async throws -> TokenSet {
        let (data, response) = try await postTokenRequest(parameters)
        guard response.isSuccess else { throw oauthError(data, response) }
        return try tokenSet(from: data, response)
    }

    /// RFC 6749 §5.2: a refused grant answers 400, or 401 for `invalid_client`.
    private static func refreshError(_ data: Data, _ response: HTTPURLResponse) -> any Error {
        if response.statusCode == 400 || response.statusCode == 401 { return OAuthError.reauthenticationRequired }
        if let error = oauthError(data, response) as? OAuthError, error.refusesRefresh {
            return OAuthError.reauthenticationRequired
        }
        return HiggsfieldError.server(status: response.statusCode)
    }

    private func postTokenRequest(_ parameters: [String: String]) async throws -> (Data, HTTPURLResponse) {
        try await session.postForm(
            server.tokenEndpoint, parameters.merging(["client_id": clientID]) { current, _ in current })
    }

    /// An unreadable 2xx body throws `HiggsfieldError.server` with its status.
    private func tokenSet(from data: Data, _ response: HTTPURLResponse) throws -> TokenSet {
        guard let body = try? decodeSnakeCase(TokenResponse.self, from: data) else {
            throw HiggsfieldError.server(status: response.statusCode)
        }
        let account = body.idToken.flatMap(IDTokenClaims.init(jwt:))
        // note: a missing expires_in is treated as one hour; refresh on 401 covers a shorter real lifetime.
        return TokenSet(
            accessToken: body.accessToken, refreshToken: body.refreshToken,
            expiresAt: now().addingTimeInterval(body.expiresIn ?? 3600), scope: body.scope ?? scope,
            clientID: clientID, issuer: server.issuer, email: account?.email, name: account?.name,
            subject: account?.subject)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?
        let scope: String?
        let idToken: String?
    }
}
