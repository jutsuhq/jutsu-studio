import HiggsfieldMCP
import JutsuCore

// The stored credential and the SDK's token set have the same fields; the SDK keeps its own type so it doesn't
// depend on the app.
extension OAuthTokens {
    public init(_ tokens: TokenSet) {
        self.init(
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt,
            scope: tokens.scope, clientID: tokens.clientID, issuer: tokens.issuer, email: tokens.email,
            name: tokens.name, subject: tokens.subject)
    }

    public var tokenSet: TokenSet {
        TokenSet(
            accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, scope: scope,
            clientID: clientID, issuer: issuer, email: email, name: name, subject: subject)
    }
}
