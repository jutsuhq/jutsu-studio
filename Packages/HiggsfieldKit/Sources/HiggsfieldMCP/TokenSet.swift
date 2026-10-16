import Foundation

/// What a token endpoint granted, plus the account the `id_token` names.
public struct TokenSet: Codable, Sendable, Hashable {
    public var accessToken: String
    /// Absent when the server didn't grant `offline_access`.
    public var refreshToken: String?
    public var expiresAt: Date
    /// Space-separated, as returned by the token endpoint.
    public var scope: String
    public var clientID: String
    /// The authorization server that issued `clientID`; a registered client ID is only valid there.
    public var issuer: URL?
    /// From the `id_token`, for display only.
    public var email: String?
    public var name: String?
    /// The `id_token`'s `sub`. Not verified: it only tells local jobs of different accounts apart.
    /// Absent when the authorization server sends no subject claim.
    public var subject: String?

    public init(
        accessToken: String, refreshToken: String?, expiresAt: Date, scope: String, clientID: String,
        issuer: URL? = nil, email: String? = nil, name: String? = nil, subject: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.clientID = clientID
        self.issuer = issuer
        self.email = email
        self.name = name
        self.subject = subject
    }
}

extension TokenSet: CustomStringConvertible {
    public var description: String {
        let refresh = refreshToken == nil ? "nil" : "<redacted>"
        return "TokenSet(accessToken: <redacted>, refreshToken: \(refresh), expiresAt: \(expiresAt), "
            + "scope: \(scope), clientID: \(clientID))"
    }
}
