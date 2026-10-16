import Foundation
import Testing

@testable import JutsuCore

private let tokens = OAuthTokens(
    accessToken: "ACCESS-SECRET", refreshToken: "REFRESH-SECRET", expiresAt: Date(timeIntervalSince1970: 0),
    scope: "openid offline_access", clientID: "https://example.com/client.json")

@Test func apiKeyDescriptionRedactsTheSecret() {
    let credential = Credential.apiKey(id: "key-id", secret: "KEY-SECRET")
    for text in [String(describing: credential), String(reflecting: credential), "\(credential)"] {
        #expect(!text.contains("KEY-SECRET"))
        #expect(text.contains("key-id"))
    }
}

@Test func oauthDescriptionRedactsBothTokens() {
    for text in [String(describing: Credential.oauth(tokens)), String(reflecting: tokens), "\(tokens)"] {
        #expect(!text.contains("ACCESS-SECRET"))
        #expect(!text.contains("REFRESH-SECRET"))
        #expect(text.contains("openid offline_access"))
    }
}

@Test func missingRefreshTokenIsShownAsNil() {
    var noRefresh = tokens
    noRefresh.refreshToken = nil
    #expect("\(noRefresh)".contains("refreshToken: nil"))
}

@Test func credentialRoundTripsThroughJSON() throws {
    for credential in [Credential.apiKey(id: "id", secret: "secret"), .oauth(tokens)] {
        let data = try JSONEncoder().encode(credential)
        #expect(try JSONDecoder().decode(Credential.self, from: data) == credential)
    }
}

@Test func tokensStoredBeforeSubjectsDecodeAndFallBackToTheEmail() throws {
    var withSubject = tokens
    withSubject.email = "me@example.com"
    withSubject.subject = "user_1"
    #expect(withSubject.owner == "user_1")
    var object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(withSubject)) as? [String: Any])
    #expect(object.removeValue(forKey: "subject") != nil)

    let legacy = try JSONDecoder().decode(OAuthTokens.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(legacy.subject == nil)
    #expect(legacy.owner == "me@example.com")
    #expect(tokens.owner == nil)
}
