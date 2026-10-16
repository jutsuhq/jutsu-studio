import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldProviders

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite(.timeLimit(.minutes(1))) struct Network {}

/// An account provider whose MCP calls and uploads all go through `session`, signed in with a token that
/// never expires. `unlimitedOptIn` is the user's Unlimited generations setting.
func makeProvider(_ session: URLSession, unlimitedOptIn: Bool = false) -> HiggsfieldMCPProvider {
    let tokens = TokenProvider(
        tokens: TokenSet(
            accessToken: "access-1", refreshToken: nil, expiresAt: .distantFuture, scope: "openid",
            clientID: "client-1"),
        refresh: { $0 }, persist: { _ in })
    let client = MCPClient(endpoint: URL(string: "https://mcp.higgsfield.ai/mcp")!, tokens: tokens, session: session)
    return HiggsfieldMCPProvider(
        account: HiggsfieldAccount(client: client, session: session), owner: "user_1",
        unlimitedOptIn: { unlimitedOptIn })
}

extension StubServer {
    func makeAPIProvider(keyID: String = "key-id") -> HiggsfieldAPIProvider {
        HiggsfieldAPIProvider(
            client: HiggsfieldAPIClient(
                keyID: keyID, secret: "key-secret", baseURL: baseURL, session: StubServer.makeSession()))
    }
}
