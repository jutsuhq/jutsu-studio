import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

private let header = "eyJhbGciOiJSUzI1NiJ9"
/// `{"email":"me@example.com","name":"Me"}`
private let payload = "eyJlbWFpbCI6Im1lQGV4YW1wbGUuY29tIiwibmFtZSI6Ik1lIn0"

@Test func idTokenPayloadIsDecoded() {
    let claims = IDTokenClaims(jwt: "\(header).\(payload).signature")
    #expect(claims == IDTokenClaims(email: "me@example.com", name: "Me"))
    #expect(IDTokenClaims(jwt: "\(header).\(payload)=.signature")?.email == "me@example.com")
}

@Test func base64URLPaddingIsOptional() {
    // `{"name":"??>"}` has a `-` and one pad; `{"name":"?~?~~"}` has a `_` and two.
    for (encoded, name) in [("eyJuYW1lIjoiPz8-In0", "??>"), ("eyJuYW1lIjoiP34_fn4ifQ", "?~?~~")] {
        for padded in [encoded, encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)] {
            let claims = IDTokenClaims(jwt: "\(header).\(padded).")
            #expect(claims?.name == name)
            #expect(claims?.email == nil)
        }
    }
}

@Test func missingOrEmptyClaimsStayNil() {
    // `{"sub":"1"}` and `{"email":"","name":7}`
    #expect(IDTokenClaims(jwt: "\(header).eyJzdWIiOiIxIn0.sig") == IDTokenClaims(subject: "1"))
    #expect(IDTokenClaims(jwt: "\(header).eyJlbWFpbCI6IiIsIm5hbWUiOjd9.sig") == IDTokenClaims())
}

@Test func garbageIsNotAnIDToken() {
    for jwt in [
        "", "garbage", "\(header).\(payload)", "\(header).\(payload).sig.extra.parts", "\(header).!!!.sig",
        "\(header)..sig", "\(header).WzFd.sig",  // `[1]`: JSON, not an object
        "\(header).bm90IGpzb24.sig",  // `not json`
        "\(header).a.sig",  // one base64 character can't decode
    ] {
        #expect(IDTokenClaims(jwt: jwt) == nil, "\(jwt)")
    }
}

extension Network {
    @Suite struct IDTokens {
        static let idToken = "\(header).\(payload).signature"

        func signIn(tokenResponse: String) async throws -> TokenSet {
            let stub = StubServer { _, _ in .json(tokenResponse) }
            let presenter = FakePresenter { "http://127.0.0.1:47613/callback?code=c&state=\($0)&\(Fixture.clerkIss)" }
            let client = Fixture.client(try Fixture.server(Fixture.clerkMetadata), session: stub.session())
            return try await PKCEAuthorizer(client: client, presenter: presenter, hasher: FakeHasher()).authorize()
        }

        @Test func tokenResponseWithIDTokenNamesTheAccount() async throws {
            let tokens = try await signIn(
                tokenResponse: #"{"access_token":"a","expires_in":60,"id_token":"\#(Self.idToken)"}"#)
            #expect(tokens.email == "me@example.com")
            #expect(tokens.name == "Me")
            #expect(tokens.issuer?.absoluteString == Fixture.clerk)
            #expect(tokens.clientID == "client-1")
        }

        @Test func tokenResponseSubjectIdentifiesTheAccount() async throws {
            // `{"sub":"user_1","email":"me@example.com"}`
            let idToken = "\(header).eyJzdWIiOiJ1c2VyXzEiLCJlbWFpbCI6Im1lQGV4YW1wbGUuY29tIn0.signature"
            let tokens = try await signIn(
                tokenResponse: #"{"access_token":"a","expires_in":60,"id_token":"\#(idToken)"}"#)
            #expect(tokens.subject == "user_1")
        }

        @Test func tokenResponseWithoutIDTokenStillSignsIn() async throws {
            let tokens = try await signIn(tokenResponse: Fixture.tokenResponse)
            #expect(tokens.accessToken == "new-access")
            #expect(tokens.email == nil)
            #expect(tokens.name == nil)
            #expect(tokens.issuer?.absoluteString == Fixture.clerk)
        }

        @Test func unreadableIDTokenIsIgnored() async throws {
            let tokens = try await signIn(tokenResponse: #"{"access_token":"a","id_token":"garbage"}"#)
            #expect(tokens.accessToken == "a")
            #expect(tokens.email == nil)
        }

        @Test func refreshWithoutIDTokenKeepsTheAccount() async throws {
            let stub = StubServer { _, _ in .json(Fixture.tokenResponse) }
            let client = Fixture.client(try Fixture.server(Fixture.clerkMetadata), session: stub.session())
            var old = Fixture.tokens(expiresAt: .distantPast)
            old.email = "me@example.com"
            old.name = "Me"
            old.subject = "user_1"
            let refreshed = try await client.refresh(old)
            #expect(refreshed.accessToken == "new-access")
            #expect(refreshed.email == "me@example.com")
            #expect(refreshed.name == "Me")
            #expect(refreshed.subject == "user_1")
        }
    }

    @Suite struct ClientReuse {
        @Test func configuredMetadataDocumentIsPreferredOverAStoredRegistration() async throws {
            let stub = StubServer { _, _ in .json(#"{"client_id":"registered-2"}"#, status: 201) }
            var previous = Fixture.tokens(expiresAt: .distantPast)
            previous.issuer = URL(string: Fixture.clerk)
            let registration = ClientRegistration(
                session: stub.session(), metadataDocumentURL: Fixture.metadataDocumentURL)
            let clientID = try await registration.clientID(
                at: try Fixture.server(Fixture.clerkMetadata), reusing: previous)
            #expect(clientID == "https://jutsuhq.github.io/jutsu-studio/oauth-client.json")
            #expect(stub.requests.isEmpty)
        }

        @Test func registeredClientIDIsReusedOnTheNextSignIn() async throws {
            let stub = StubServer { request, _ in
                request.url.path == "/oauth/register"
                    ? .json(#"{"client_id":"registered-1"}"#, status: 201) : .json(Fixture.tokenResponse)
            }
            // The real clerk document: it accepts metadata documents, but none is configured by default.
            let server = try Fixture.server(Fixture.clerkMetadata)
            let registration = ClientRegistration(session: stub.session())

            let first = try await registration.clientID(at: server)
            let client = OAuthClient(server: server, clientID: first, resource: Fixture.mcpURL, session: stub.session())
            let presenter = FakePresenter { "http://127.0.0.1:47613/callback?code=c&state=\($0)&\(Fixture.clerkIss)" }
            let tokens = try await PKCEAuthorizer(client: client, presenter: presenter, hasher: FakeHasher())
                .authorize()
            let second = try await registration.clientID(at: server, reusing: tokens)

            #expect(first == "registered-1")
            #expect(second == "registered-1")
            #expect(stub.requests(to: "\(Fixture.clerk)/oauth/register").count == 1)
        }

        @Test func registrationIsReusedWhenTheIssuerDiffersOnlyByATrailingSlash() async throws {
            let stub = StubServer { _, _ in .json(#"{"client_id":"registered-2"}"#, status: 201) }
            var previous = Fixture.tokens(expiresAt: .distantPast)
            previous.issuer = URL(string: Fixture.clerk + "/")
            previous.clientID = "registered-1"
            let clientID = try await ClientRegistration(session: stub.session())
                .clientID(at: try Fixture.server(Fixture.clerkWithoutCIMD), reusing: previous)
            #expect(clientID == "registered-1")
            #expect(stub.requests.isEmpty)
        }

        @Test func registrationAtAnotherIssuerIsNotReused() async throws {
            let stub = StubServer { _, _ in .json(#"{"client_id":"registered-2"}"#, status: 201) }
            var elsewhere = Fixture.tokens(expiresAt: .distantPast)
            elsewhere.issuer = URL(string: Fixture.deviceAuth)
            let unknownIssuer = Fixture.tokens(expiresAt: .distantPast)
            for previous in [elsewhere, unknownIssuer] {
                let clientID = try await ClientRegistration(session: stub.session())
                    .clientID(at: try Fixture.server(Fixture.clerkWithoutCIMD), reusing: previous)
                #expect(clientID == "registered-2")
            }
            #expect(stub.requests.count == 2)
        }

        @Test func metadataDocumentClientIDIsNeverReusedForRegistration() async throws {
            let stub = StubServer { _, _ in .json(#"{"client_id":"registered-2"}"#, status: 201) }
            var previous = Fixture.tokens(expiresAt: .distantPast)
            previous.issuer = URL(string: Fixture.clerk)
            previous.clientID = "https://jutsuhq.github.io/jutsu-studio/oauth-client.json"
            let clientID = try await ClientRegistration(session: stub.session())
                .clientID(at: try Fixture.server(Fixture.clerkWithoutCIMD), reusing: previous)
            #expect(clientID == "registered-2")
        }
    }
}
