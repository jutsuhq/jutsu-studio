import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

@Test func wwwAuthenticateParametersAreParsed() {
    let parameters = OAuthDiscovery.challengeParameters(Fixture.wwwAuthenticate)
    #expect(parameters["resource_metadata"] == Fixture.resourceMetadataURL)
    #expect(parameters["scope"] == "openid email offline_access")
    #expect(OAuthDiscovery.challengeParameters(#"Bearer realm=mcp, error="invalid_token""#)["realm"] == "mcp")
}

@Test func wellKnownURLsFollowRFC9728AndRFC8414() throws {
    let resource = OAuthDiscovery.resourceMetadataURLs(for: Fixture.mcpURL).map(\.absoluteString)
    #expect(
        resource == [Fixture.resourceMetadataURL, "https://mcp.higgsfield.ai/.well-known/oauth-protected-resource"])
    let issuer = try #require(URL(string: Fixture.clerk))
    #expect(
        OAuthDiscovery.authorizationServerMetadataURLs(for: issuer).map(\.absoluteString) == [
            "\(Fixture.clerk)/.well-known/oauth-authorization-server",
            "\(Fixture.clerk)/.well-known/openid-configuration",
        ])
}

extension Network {
    @Suite struct Discovery {
        /// The servers as recorded: resource metadata, clerk on RFC 8414, and the device server's 404s.
        static func server(resource: String = Fixture.resourceMetadata) -> StubServer {
            StubServer { request, _ in
                switch request.url.absoluteString {
                case Fixture.resourceMetadataURL: .json(resource)
                case "\(Fixture.clerk)/.well-known/oauth-authorization-server": .json(Fixture.clerkMetadata)
                default: .json(Fixture.notFoundBody, status: 404)
                }
            }
        }

        /// A host whose every metadata URL fails like a DNS lookup that finds nothing.
        static func unreachableHost() -> StubServer {
            let host = StubServer()
            for path in [
                "/.well-known/oauth-authorization-server", "/.well-known/openid-configuration",
                "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource",
            ] {
                host.on("GET", path, fail: URLError(.cannotFindHost))
            }
            return host
        }

        /// The recorded resource document with `authorizationServers` in place of the advertised ones.
        static func resource(authorizationServers: [String]) throws -> String {
            var object = try #require(
                try JSONDecoder().decode(JSONValue.self, from: Data(Fixture.resourceMetadata.utf8)).objectValue)
            object["authorization_servers"] = .array(authorizationServers.map(JSONValue.string))
            return String(decoding: try JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)
        }

        @Test func readsRecordedMetadata() async throws {
            let stub = Self.server()
            let discovered = try await OAuthDiscovery(session: stub.session())
                .discover(mcpURL: Fixture.mcpURL, wwwAuthenticate: Fixture.wwwAuthenticate)

            #expect(stub.requests.first?.url.absoluteString == Fixture.resourceMetadataURL)
            #expect(
                discovered.resource.authorizationServers.map(\.absoluteString) == [Fixture.clerk, Fixture.deviceAuth])
            #expect(discovered.resource.scopesSupported == ["openid", "email", "offline_access"])
            #expect(discovered.servers.map(\.issuer.absoluteString) == [Fixture.clerk])

            let pkce = try #require(discovered.authorizationCodeServer)
            #expect(pkce.authorizationEndpoint?.absoluteString == "\(Fixture.clerk)/oauth/authorize")
            #expect(pkce.tokenEndpoint.absoluteString == "\(Fixture.clerk)/oauth/token")
            #expect(pkce.registrationEndpoint?.absoluteString == "\(Fixture.clerk)/oauth/register")
            #expect(pkce.clientIDMetadataDocumentSupported)
            #expect(pkce.authorizationResponseIssParameterSupported)
        }

        @Test func deviceServerWithoutMetadataIsLeftOut() async throws {
            let stub = Self.server()
            let discovered = try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)

            #expect(!stub.requests(to: "\(Fixture.deviceAuth)/.well-known/oauth-authorization-server").isEmpty)
            #expect(!stub.requests(to: "\(Fixture.deviceAuth)/.well-known/openid-configuration").isEmpty)
            #expect(discovered.authorizationCodeServer?.issuer.absoluteString == Fixture.clerk)
        }

        @Test func unreachableServerDoesNotHideOneThatAnswers() async throws {
            let unreachable = Self.unreachableHost()
            let stub = Self.server(
                resource: try Self.resource(authorizationServers: [unreachable.baseURL.absoluteString, Fixture.clerk]))
            let discovered = try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)

            #expect(unreachable.requests.count == 2)
            #expect(discovered.servers.map(\.issuer.absoluteString) == [Fixture.clerk])
        }

        @Test func noReachableServerIsANetworkFailure() async throws {
            let unreachable = Self.unreachableHost()
            let stub = Self.server(
                resource: try Self.resource(authorizationServers: [unreachable.baseURL.absoluteString]))
            await #expect(throws: HiggsfieldError.network) {
                try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)
            }
            await #expect(throws: HiggsfieldError.network) {
                try await OAuthDiscovery(session: stub.session())
                    .discover(mcpURL: unreachable.baseURL.appendingPathComponent("mcp"))
            }
        }

        @Test func fallsBackToRootResourceMetadata() async throws {
            let stub = StubServer { request, _ in
                switch request.url.absoluteString {
                case "https://mcp.higgsfield.ai/.well-known/oauth-protected-resource": .json(Fixture.resourceMetadata)
                case "\(Fixture.clerk)/.well-known/oauth-authorization-server": .json(Fixture.clerkMetadata)
                default: .notFound
                }
            }
            let discovered = try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)
            #expect(discovered.servers.map(\.issuer.absoluteString) == [Fixture.clerk])
        }

        @Test func mcpHostMetadataDecodes() throws {
            let host = try Fixture.server(Fixture.mcpHostMetadata)
            #expect(host.supportsAuthorizationCode)
            #expect(host.clientIDMetadataDocumentSupported)
            #expect(!host.authorizationResponseIssParameterSupported)
        }

        @Test func failsWithoutMetadata() async {
            let stub = StubServer { _, _ in .notFound }
            await #expect(throws: OAuthError.discoveryFailed) {
                try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)
            }
        }
    }
}
