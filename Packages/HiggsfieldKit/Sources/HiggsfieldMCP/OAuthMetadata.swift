import Foundation
import HiggsfieldCore

/// OAuth 2.0 Protected Resource Metadata (RFC 9728).
public struct ProtectedResourceMetadata: Decodable, Sendable, Hashable {
    public var resource: URL
    public var authorizationServers: [URL]
    public var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    /// RFC 9728 §3.3: `resource` must be the resource the metadata was fetched for, or the document is ignored.
    func describes(_ expected: URL) -> Bool {
        resource.isSameResource(as: expected)
    }
}

/// OAuth 2.0 Authorization Server Metadata (RFC 8414), the fields this client uses.
public struct AuthorizationServerMetadata: Decodable, Sendable, Hashable {
    public var issuer: URL
    public var authorizationEndpoint: URL?
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    /// RFC 7009 token revocation.
    public var revocationEndpoint: URL?
    public var grantTypesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?
    public var clientIDMetadataDocumentSupported: Bool
    /// RFC 9207: the server puts `iss` on every authorization response, so one without it is rejected.
    public var authorizationResponseIssParameterSupported: Bool

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case clientIDMetadataDocumentSupported = "client_id_metadata_document_supported"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issuer = try container.decode(URL.self, forKey: .issuer)
        authorizationEndpoint = try container.decodeIfPresent(URL.self, forKey: .authorizationEndpoint)
        tokenEndpoint = try container.decode(URL.self, forKey: .tokenEndpoint)
        registrationEndpoint = try container.decodeIfPresent(URL.self, forKey: .registrationEndpoint)
        revocationEndpoint = try container.decodeIfPresent(URL.self, forKey: .revocationEndpoint)
        grantTypesSupported = try container.decodeIfPresent([String].self, forKey: .grantTypesSupported)
        codeChallengeMethodsSupported = try container.decodeIfPresent(
            [String].self, forKey: .codeChallengeMethodsSupported)
        clientIDMetadataDocumentSupported =
            try container.decodeIfPresent(Bool.self, forKey: .clientIDMetadataDocumentSupported) ?? false
        authorizationResponseIssParameterSupported =
            try container.decodeIfPresent(Bool.self, forKey: .authorizationResponseIssParameterSupported) ?? false
    }

    /// RFC 8414 §3.3: `issuer` must be the issuer the metadata was fetched for. Every endpoint has to be https,
    /// since the authorization endpoint is opened in the browser and the others receive codes and tokens.
    func isIssued(by expected: URL) -> Bool {
        let endpoints = [authorizationEndpoint, tokenEndpoint, registrationEndpoint, revocationEndpoint]
        return issuer.isSameResource(as: expected) && issuer.isHTTPS && endpoints.allSatisfy { $0?.isHTTPS ?? true }
    }

    /// Authorization code with PKCE S256, the only flow this app signs in with. RFC 8414 §2: an absent grant
    /// list means `authorization_code` and `implicit`.
    var supportsAuthorizationCode: Bool {
        authorizationEndpoint != nil
            && (grantTypesSupported ?? [GrantType.authorizationCode]).contains(GrantType.authorizationCode)
            && codeChallengeMethodsSupported?.contains("S256") == true
    }
}

/// `grant_type` values this client sends.
enum GrantType {
    static let authorizationCode = "authorization_code"
    static let refreshToken = "refresh_token"
}

extension URL {
    /// Equal up to a trailing slash, which servers add or drop inconsistently.
    func isSameResource(as other: URL) -> Bool {
        trimmingTrailingSlash == other.trimmingTrailingSlash
    }

    var trimmingTrailingSlash: String {
        let text = absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}
