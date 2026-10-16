import Foundation

/// Authorization code flow with PKCE S256, `state` and `resource` (OAuth 2.1, RFC 7636, RFC 8707).
public struct PKCEAuthorizer: Sendable {
    private let client: OAuthClient
    private let presenter: any AuthorizationPresenter
    private let hasher: any PKCEHasher

    public init(client: OAuthClient, presenter: any AuthorizationPresenter, hasher: any PKCEHasher) {
        self.client = client
        self.presenter = presenter
        self.hasher = hasher
    }

    public func authorize() async throws -> TokenSet {
        guard let endpoint = client.server.authorizationEndpoint, client.server.supportsAuthorizationCode else {
            throw OAuthError.unsupportedFlow
        }
        let pkce = PKCE(hasher: hasher)
        let state = randomURLSafeString(length: 32)
        let redirect = try await presenter.authorize { redirectURI in
            try authorizationURL(endpoint: endpoint, pkce: pkce, state: state, redirectURI: redirectURI)
        }
        let code = try Self.code(
            from: redirect.callback, expectedState: state, issuer: client.server.issuer,
            requiresIssuer: client.server.authorizationResponseIssParameterSupported)
        return try await client.requestTokens([
            "grant_type": GrantType.authorizationCode,
            "code": code,
            "redirect_uri": redirect.redirectURI,
            "code_verifier": pkce.verifier,
            "resource": client.resource.absoluteString,
        ])
    }

    func authorizationURL(endpoint: URL, pkce: PKCE, state: String, redirectURI: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.unsupportedFlow
        }
        let existing = components.queryItems ?? []
        components.queryItems =
            existing + [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: client.clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: client.scope),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "resource", value: client.resource.absoluteString),
            ]
        guard let url = components.url else { throw OAuthError.unsupportedFlow }
        return url
    }

    /// The `code` of a redirect, after checking `state` first so a forged redirect never reaches the token endpoint.
    /// RFC 9207: `iss` must name `issuer`. It may be missing only when the server doesn't advertise sending it
    /// (`requiresIssuer` false).
    static func code(from callback: URL, expectedState: String, issuer: URL, requiresIssuer: Bool) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw OAuthError.stateMismatch }
        if let iss = value("iss") {
            guard URL(string: iss)?.isSameResource(as: issuer) == true else { throw OAuthError.issuerMismatch }
        } else if requiresIssuer {
            throw OAuthError.issuerMismatch
        }
        if let error = value("error") {
            throw error == "access_denied"
                ? OAuthError.accessDenied : OAuthError.server(code: error, description: value("error_description"))
        }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.invalidCallback }
        return code
    }
}

#if canImport(CryptoKit)
    extension PKCEAuthorizer {
        public init(client: OAuthClient, presenter: any AuthorizationPresenter) {
            self.init(client: client, presenter: presenter, hasher: CryptoKitHasher())
        }
    }
#endif
