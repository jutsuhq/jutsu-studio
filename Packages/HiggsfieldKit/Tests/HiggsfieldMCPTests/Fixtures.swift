import Foundation
import HiggsfieldCore

@testable import HiggsfieldMCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Documents as fetched from the live servers on 2026-10-13 (ARCHITECTURE.md §5.1), verbatim.
// fnf-device-auth.higgsfield.ai answered 404 on both well-known paths.
enum Fixture {
    static let mcpURL = URL(string: "https://mcp.higgsfield.ai/mcp") ?? URL(fileURLWithPath: "/")
    static let resourceMetadataURL = "https://mcp.higgsfield.ai/.well-known/oauth-protected-resource/mcp"
    static let wwwAuthenticate =
        #"Bearer resource_metadata="https://mcp.higgsfield.ai/.well-known/oauth-protected-resource/mcp", "#
        + #"scope="openid email offline_access""#

    static let clerk = "https://clerk.higgsfield.ai"
    static let deviceAuth = "https://fnf-device-auth.higgsfield.ai"
    /// The `iss` query item clerk puts on its redirect (RFC 9207), percent-encoded.
    static let clerkIss = "iss=https%3A%2F%2Fclerk.higgsfield.ai"
    /// Where `docs/oauth-client.json` would be served.
    static let metadataDocumentURL = URL(string: "https://jutsuhq.github.io/jutsu-studio/oauth-client.json")

    static let resourceMetadata = #"""
        {"resource":"https://mcp.higgsfield.ai/mcp","authorization_servers":["https://clerk.higgsfield.ai","https://fnf-device-auth.higgsfield.ai"],"scopes_supported":["openid","email","offline_access"],"bearer_methods_supported":["header"],"higgsfield_auth_hints":{"selection":"client_capability_based","options":[{"flow":"authorization_code_pkce","authorization_server":"https://clerk.higgsfield.ai","potential_clients":["anthropic","claude","claude-ai","claude-code"],"use_when":"Client can complete an OAuth authorization-code redirect using one of its registered redirect mechanisms.","requires":["authorization_endpoint","token_endpoint","redirect_uri_receiver","pkce"]},{"flow":"device_code","authorization_server":"https://fnf-device-auth.higgsfield.ai","potential_clients":["openclaw","hermes","memoclaw"],"use_when":"Client cannot receive authorization-code redirects and should ask the user to complete verification out-of-band.","requires":["device_authorization_endpoint","token_polling"]}]}}
        """#

    static let clerkMetadata = #"""
        {"issuer":"https://clerk.higgsfield.ai","authorization_endpoint":"https://clerk.higgsfield.ai/oauth/authorize","token_endpoint":"https://clerk.higgsfield.ai/oauth/token","revocation_endpoint":"https://clerk.higgsfield.ai/oauth/token/revoke","device_authorization_endpoint":"https://clerk.higgsfield.ai/oauth/device_authorization","jwks_uri":"https://clerk.higgsfield.ai/.well-known/jwks.json","registration_endpoint":"https://clerk.higgsfield.ai/oauth/register","response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token","urn:ietf:params:oauth:grant-type:device_code"],"token_endpoint_auth_methods_supported":["client_secret_basic","none","client_secret_post"],"scopes_supported":["openid","profile","email","public_metadata","private_metadata","offline_access","user:org:read"],"subject_types_supported":["public"],"id_token_signing_alg_values_supported":["RS256"],"code_challenge_methods_supported":["S256"],"client_id_metadata_document_supported":true,"authorization_response_iss_parameter_supported":true}
        """#

    /// Served by the MCP host itself, but not listed in `authorization_servers`.
    static let mcpHostMetadata = #"""
        {"issuer":"https://mcp.higgsfield.ai","authorization_endpoint":"https://mcp.higgsfield.ai/oauth2/authorize","token_endpoint":"https://mcp.higgsfield.ai/oauth2/token","registration_endpoint":"https://mcp.higgsfield.ai/oauth2/register","client_id_metadata_document_supported":true,"response_types_supported":["code"],"response_modes_supported":["form_post","query"],"grant_types_supported":["authorization_code","refresh_token","urn:ietf:params:oauth:grant-type:device_code"],"token_endpoint_auth_methods_supported":["client_secret_basic","none","client_secret_post"],"code_challenge_methods_supported":["S256"],"scopes_supported":["openid","email","offline_access"],"claims_supported":["aud","email","email_verified","exp","family_name","given_name","iat","iss","name","picture","preferred_username","sub","org_id"]}
        """#

    static let notFoundBody = #"{"detail":"Not Found"}"#

    /// The real clerk document minus Client ID Metadata Document support, to force dynamic registration.
    static let clerkWithoutCIMD = clerkMetadata.replacingOccurrences(
        of: #""client_id_metadata_document_supported":true"#, with: #""client_id_metadata_document_supported":false"#)

    static func server(_ json: String) throws -> AuthorizationServerMetadata {
        try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(json.utf8))
    }

    static func client(
        _ server: AuthorizationServerMetadata, session: URLSession, now: Date = .distantPast
    )
        -> OAuthClient
    {
        OAuthClient(server: server, clientID: "client-1", resource: mcpURL, session: session, now: { now })
    }

    static func tokens(access: String = "access-1", refresh: String? = "refresh-1", expiresAt: Date) -> TokenSet {
        TokenSet(
            accessToken: access, refreshToken: refresh, expiresAt: expiresAt, scope: OAuthClient.defaultScope,
            clientID: "client-1")
    }

    static let tokenResponse = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#
}
