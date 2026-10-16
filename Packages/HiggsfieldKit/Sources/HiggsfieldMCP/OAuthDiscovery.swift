import Foundation
import HiggsfieldCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Everything sign-in needs to know about an MCP server, read from its metadata documents.
public struct DiscoveredAuthorization: Sendable, Hashable {
    public var resource: ProtectedResourceMetadata
    /// In the order the resource lists them; servers whose metadata couldn't be read are left out.
    public var servers: [AuthorizationServerMetadata]

    /// The first readable server that offers the authorization code flow with PKCE.
    public var authorizationCodeServer: AuthorizationServerMetadata? {
        servers.first(where: \.supportsAuthorizationCode)
    }

    /// The client that `tokens` were issued to, for refreshing or revoking them. Refresh tokens go only to
    /// the server that issued them: when it is no longer advertised, or `tokens` don't name it, the user
    /// has to sign in again.
    public func client(issuing tokens: TokenSet, session: URLSession = .shared) throws -> OAuthClient {
        guard let issuer = tokens.issuer, let server = servers.first(where: { $0.issuer.isSameResource(as: issuer) })
        else { throw OAuthError.reauthenticationRequired }
        return OAuthClient(server: server, clientID: tokens.clientID, resource: resource.resource, session: session)
    }
}

/// Reads protected resource metadata (RFC 9728) and then each authorization server's metadata
/// (RFC 8414, falling back to OpenID Connect discovery). No endpoint is hard-coded.
public struct OAuthDiscovery: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// - Parameter wwwAuthenticate: the header of a `401` from the MCP endpoint, when there was one;
    ///   its `resource_metadata` URL is tried first.
    public func discover(mcpURL: URL, wwwAuthenticate: String? = nil) async throws -> DiscoveredAuthorization {
        var candidates = Self.resourceMetadataURLs(for: mcpURL)
        if let header = wwwAuthenticate, let hinted = Self.challengeParameters(header)["resource_metadata"],
            let url = URL(string: hinted), url.isHTTPS
        {
            candidates.insert(url, at: 0)
        }
        guard
            let resource = try await firstDocument(
                ProtectedResourceMetadata.self, at: candidates, where: { $0.describes(mcpURL) })
        else {
            throw OAuthError.discoveryFailed
        }
        var servers: [AuthorizationServerMetadata] = []
        var unreachable = false
        for issuer in resource.authorizationServers where issuer.isHTTPS {
            // One advertised server that can't be reached must not hide another that answers.
            do {
                if let server = try await firstDocument(
                    AuthorizationServerMetadata.self, at: Self.authorizationServerMetadataURLs(for: issuer),
                    where: { $0.isIssued(by: issuer) })
                {
                    servers.append(server)
                }
            } catch HiggsfieldError.network {
                unreachable = true
            }
        }
        guard !servers.isEmpty else { throw unreachable ? HiggsfieldError.network : OAuthError.discoveryFailed }
        return DiscoveredAuthorization(resource: resource, servers: servers)
    }

    /// RFC 9728 §3.1: the well-known suffix goes between host and path, then the bare root as fallback.
    static func resourceMetadataURLs(for resource: URL) -> [URL] {
        wellKnownURLs(for: resource, suffix: "oauth-protected-resource")
    }

    /// RFC 8414 §3.1 path insertion, then OpenID Connect's appended `openid-configuration`.
    static func authorizationServerMetadataURLs(for issuer: URL) -> [URL] {
        let openID = url(issuer, path: trimmedPath(issuer) + "/.well-known/openid-configuration")
        return wellKnownURLs(for: issuer, suffix: "oauth-authorization-server") + [openID].compactMap { $0 }
    }

    /// Parameters of a `Bearer` challenge: `Bearer realm="x", resource_metadata="https://..."`.
    static func challengeParameters(_ header: String) -> [String: String] {
        var parameters: [String: String] = [:]
        var rest = Substring(header)
        if let space = rest.firstIndex(of: " ") { rest = rest[rest.index(after: space)...] }
        while let equals = rest.firstIndex(of: "=") {
            let key = rest[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " ,")).lowercased()
            rest = rest[rest.index(after: equals)...]
            let value: Substring
            if rest.first == "\"", let close = rest.dropFirst().firstIndex(of: "\"") {
                value = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end]
                rest = rest[end...]
            }
            parameters[key] = value.trimmingCharacters(in: .whitespaces)
        }
        return parameters
    }

    private static func wellKnownURLs(for resource: URL, suffix: String) -> [URL] {
        let path = trimmedPath(resource)
        let root = "/.well-known/" + suffix
        return (path.isEmpty ? [root] : [root + path, root]).compactMap { url(resource, path: $0) }
    }

    private static func trimmedPath(_ url: URL) -> String {
        url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
    }

    /// `base`'s scheme, host and port with `path`.
    private static func url(_ base: URL, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        components.path = path
        return components.url
    }

    /// The first URL that answers 2xx with a decodable document that passes `isValid`. URLs that can't be reached
    /// are skipped. `nil` when none has such a document; throws `HiggsfieldError.network` when none answered at all.
    private func firstDocument<T: Decodable>(
        _ type: T.Type, at urls: [URL], where isValid: (T) -> Bool
    ) async throws -> T? {
        var answered = false
        for url in urls {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await session.send(request)
            } catch HiggsfieldError.network {
                continue
            }
            answered = true
            if response.isSuccess, let document = try? JSONDecoder().decode(type, from: data), isValid(document) {
                return document
            }
        }
        guard answered else { throw HiggsfieldError.network }
        return nil
    }
}
