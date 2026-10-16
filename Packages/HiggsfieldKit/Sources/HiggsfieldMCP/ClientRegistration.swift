import Foundation
import HiggsfieldCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Obtains this app's `client_id` at an authorization server: dynamic client registration (RFC 7591),
/// or the URL of a Client ID Metadata Document when one is configured and the server accepts it.
public struct ClientRegistration: Sendable {
    /// Loopback redirects (RFC 8252 §7.3): the browser hands the code to a listener in the app, which works
    /// with every default browser. The ports are fixed so the registered redirect URIs match exactly; the
    /// listener binds the first free one.
    public static let loopbackPorts: [UInt16] = [47613, 51874, 58329]
    static let clientName = "Jutsu Studio"

    private let session: URLSession
    private let metadataDocumentURL: URL?

    /// - Parameter metadataDocumentURL: a published Client ID Metadata Document; `nil` always registers.
    public init(session: URLSession = .shared, metadataDocumentURL: URL? = nil) {
        self.session = session
        self.metadataDocumentURL = metadataDocumentURL
    }

    /// Registration is not idempotent, so a `client_id` registered earlier at the same server is reused:
    /// pass the tokens it was stored with as `previous`.
    public func clientID(
        at server: AuthorizationServerMetadata, reusing previous: TokenSet? = nil
    ) async throws
        -> String
    {
        if server.clientIDMetadataDocumentSupported, let metadataDocumentURL {
            return metadataDocumentURL.absoluteString
        }
        // A metadata document client ID is an HTTPS URL; registered IDs never are.
        if let previous, previous.issuer?.isSameResource(as: server.issuer) == true,
            !previous.clientID.hasPrefix("https://")
        {
            return previous.clientID
        }
        guard let endpoint = server.registrationEndpoint else { throw OAuthError.registrationUnavailable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Self.registrationRequest)
        let (data, response) = try await session.send(request)
        guard response.isSuccess else { throw oauthError(data, response) }
        guard let clientID = (try? JSONDecoder().decode(JSONValue.self, from: data))?["client_id"]?.stringValue else {
            throw OAuthError.registrationUnavailable
        }
        return clientID
    }

    public static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/callback"
    }

    static let registrationRequest: JSONValue = [
        "client_name": .string(clientName),
        "redirect_uris": .array(loopbackPorts.map { .string(redirectURI(port: $0)) }),
        "grant_types": [.string(GrantType.authorizationCode), .string(GrantType.refreshToken)],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
    ]
}
