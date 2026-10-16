import Foundation
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

// Discovery validation (RFC 9728 §3.3, RFC 8414 §3.3, https only) and refresh pinned to the issuing server.

@Test func recordedClerkMetadataPassesValidation() throws {
    let clerk = try Fixture.server(Fixture.clerkMetadata)
    let issuer = try #require(URL(string: Fixture.clerk))
    let withSlash = try #require(URL(string: Fixture.clerk + "/"))
    #expect(clerk.isIssued(by: issuer))
    #expect(clerk.isIssued(by: withSlash))
    #expect(clerk.revocationEndpoint?.absoluteString == "\(Fixture.clerk)/oauth/token/revoke")
}

@Test func metadataForAnotherIssuerIsRejected() throws {
    let clerk = try Fixture.server(Fixture.clerkMetadata)
    let other = try #require(URL(string: "https://evil.example"))
    #expect(!clerk.isIssued(by: other))
}

@Test(arguments: [
    "https://clerk.higgsfield.ai/oauth/authorize", "https://clerk.higgsfield.ai/oauth/token",
    "https://clerk.higgsfield.ai/oauth/register", "https://clerk.higgsfield.ai/oauth/token/revoke",
])
func nonHTTPSEndpointIsRejected(endpoint: String) throws {
    let downgraded = Fixture.clerkMetadata.replacingOccurrences(
        of: "\"\(endpoint)\"", with: "\"file:///Applications/Calculator.app\"")
    #expect(downgraded != Fixture.clerkMetadata)
    let issuer = try #require(URL(string: Fixture.clerk))
    let server = try Fixture.server(downgraded)
    #expect(!server.isIssued(by: issuer))
}

@Test func resourceMetadataMustNameTheMCPURL() throws {
    let resource = try JSONDecoder().decode(ProtectedResourceMetadata.self, from: Data(Fixture.resourceMetadata.utf8))
    #expect(resource.describes(Fixture.mcpURL))
    let other = try #require(URL(string: "https://mcp.higgsfield.ai/other"))
    #expect(!resource.describes(other))
}

@Suite struct IssuerPinning {
    static func discovered() throws -> DiscoveredAuthorization {
        let resource = try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: Data(Fixture.resourceMetadata.utf8))
        return DiscoveredAuthorization(resource: resource, servers: [try Fixture.server(Fixture.mcpHostMetadata)])
    }

    static func tokens(issuer: String?) -> TokenSet {
        var tokens = Fixture.tokens(expiresAt: .distantPast)
        tokens.issuer = issuer.flatMap(URL.init(string:))
        return tokens
    }

    @Test func refreshUsesTheIssuingServer() throws {
        let client = try Self.discovered().client(issuing: Self.tokens(issuer: "https://mcp.higgsfield.ai/"))
        #expect(client.server.tokenEndpoint.absoluteString == "https://mcp.higgsfield.ai/oauth2/token")
        #expect(client.clientID == "client-1")
        #expect(client.resource == Fixture.mcpURL)
    }

    @Test func tokensOfAnUnlistedIssuerNeedANewSignIn() throws {
        // The MCP host is the only server: clerk's tokens must not go to it, even though it can refresh.
        let discovered = try Self.discovered()
        #expect(throws: OAuthError.reauthenticationRequired) {
            _ = try discovered.client(issuing: Self.tokens(issuer: Fixture.clerk))
        }
        #expect(throws: OAuthError.reauthenticationRequired) {
            _ = try discovered.client(issuing: Self.tokens(issuer: nil))
        }
    }
}

extension Network {
    @Suite struct DiscoveryValidation {
        static func server(
            resource: String = Fixture.resourceMetadata, clerk: String = Fixture.clerkMetadata
        )
            -> StubServer
        {
            StubServer { request, _ in
                switch request.url.absoluteString {
                case Fixture.resourceMetadataURL: .json(resource)
                case "\(Fixture.clerk)/.well-known/oauth-authorization-server": .json(clerk)
                default: .notFound
                }
            }
        }

        @Test func resourceForAnotherURLFailsDiscovery() async {
            let foreign = Fixture.resourceMetadata.replacingOccurrences(
                of: #""resource":"https://mcp.higgsfield.ai/mcp""#, with: #""resource":"https://evil.example/mcp""#)
            let stub = Self.server(resource: foreign)
            await #expect(throws: OAuthError.discoveryFailed) {
                try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)
            }
            #expect(stub.requests(to: "\(Fixture.clerk)/.well-known/oauth-authorization-server").isEmpty)
        }

        @Test func serverClaimingAnotherIssuerIsLeftOut() async {
            let mixedUp = Fixture.clerkMetadata.replacingOccurrences(
                of: #""issuer":"https://clerk.higgsfield.ai""#, with: #""issuer":"https://evil.example""#)
            let stub = Self.server(clerk: mixedUp)
            await #expect(throws: OAuthError.discoveryFailed) {
                try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)
            }
        }

        @Test func plainHTTPAuthorizationEndpointIsLeftOut() async {
            let downgraded = Fixture.clerkMetadata.replacingOccurrences(
                of: "https://clerk.higgsfield.ai/oauth/authorize", with: "http://clerk.higgsfield.ai/oauth/authorize")
            let stub = Self.server(clerk: downgraded)
            await #expect(throws: OAuthError.discoveryFailed) {
                try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)
            }
        }

        @Test func plainHTTPAuthorizationServerIsNeverFetched() async {
            let downgraded = Fixture.resourceMetadata.replacingOccurrences(
                of: #""authorization_servers":["https://clerk.higgsfield.ai""#,
                with: #""authorization_servers":["http://clerk.higgsfield.ai""#)
            let stub = Self.server(resource: downgraded)
            await #expect(throws: OAuthError.discoveryFailed) {
                try await OAuthDiscovery(session: stub.session()).discover(mcpURL: Fixture.mcpURL)
            }
            #expect(!stub.requests.contains { $0.url.host == "clerk.higgsfield.ai" })
        }

        @Test func revokeSendsTheRefreshTokenToTheRevocationEndpoint() async throws {
            let stub = StubServer { _, _ in StubResponse(status: 200) }
            let clerk = try Fixture.server(Fixture.clerkMetadata)
            try await Fixture.client(clerk, session: stub.session()).revoke(Fixture.tokens(expiresAt: .distantPast))

            let request = try #require(stub.requests.first)
            #expect(request.url.absoluteString == "\(Fixture.clerk)/oauth/token/revoke")
            #expect(request.bodyText == "client_id=client-1&token=refresh-1&token_type_hint=refresh_token")
        }
    }
}
