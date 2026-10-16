import AppKit
import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldProviders
import JutsuCore
import Presentation
import Secrets
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Connection")

enum Higgsfield {
    // swiftlint:disable:next force_unwrapping
    static let mcpEndpoint = URL(string: "https://mcp.higgsfield.ai/mcp")!
    // swiftlint:disable:next force_unwrapping
    static let consoleURL = URL(string: "https://console.higgsfield.ai")!
}

/// `KeychainStore.activeConnection` as the `CredentialVault` the connection store writes to.
struct KeychainVault: CredentialVault {
    let store: KeychainStore

    func saveData(_ data: Data) throws { try store.saveData(data) }
    func loadData() throws -> Data? { try store.loadData() }
    func delete() throws { try store.delete() }
}

/// The network side of onboarding: key validation over REST, account sign-in over OAuth.
struct HiggsfieldConnectionServices: ConnectionServices {
    func validateAPIKey(id: String, secret: String) async throws -> Bool {
        try await HiggsfieldAPIClient(keyID: id, secret: secret).validateKey()
    }

    func signInWithBrowser(
        reusing previous: OAuthTokens?, show: @escaping @Sendable (URL) async -> Void
    ) async throws -> OAuthTokens {
        // The browser keeps focus after the redirect; bring the app back for the result.
        defer { Task { @MainActor in NSApp.activate() } }
        // A browser that doesn't open doesn't end the sign-in: the sheet offers the link to open again or copy.
        let presenter = LoopbackAuthorizationPresenter { url in
            // `NSWorkspace.open` would hand any scheme to its app; discovery already demands https.
            guard url.scheme?.lowercased() == "https" else { throw SignInError.invalidResponse }
            await show(url)
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            if !opened { logger.error("The default browser didn't open the sign-in page") }
        }
        do {
            let client = try await AccountAuthorization.client(reusing: previous)
            return OAuthTokens(try await PKCEAuthorizer(client: client, presenter: presenter).authorize())
        } catch {
            throw AccountSignIn.error(for: error)
        }
    }

    func revoke(_ tokens: OAuthTokens) async {
        do {
            try await AccountAuthorization.revoke(tokens.tokenSet)
        } catch {
            logger.info("Can't revoke the signed-out tokens: \(String(describing: error), privacy: .private)")
        }
    }
}

enum AccountAuthorization {
    /// The OAuth client at the first server offering the authorization code flow. Endpoints are discovered on
    /// every sign-in and refresh, never hard-coded (ARCHITECTURE §5.2). A known `clientID` skips registration;
    /// `previous` lets registration reuse the client ID stored with earlier tokens.
    static func client(clientID: String? = nil, reusing previous: OAuthTokens? = nil) async throws -> OAuthClient {
        let discovered = try await OAuthDiscovery().discover(mcpURL: Higgsfield.mcpEndpoint)
        guard let server = discovered.authorizationCodeServer else { throw OAuthError.unsupportedFlow }
        let id: String
        if let clientID {
            id = clientID
        } else {
            id = try await ClientRegistration().clientID(at: server, reusing: previous?.tokenSet)
        }
        return OAuthClient(server: server, clientID: id, resource: discovered.resource.resource)
    }

    /// Refreshes at the server that issued `tokens` only; fails with `reauthenticationRequired` when discovery
    /// no longer lists it.
    static func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        let discovered = try await OAuthDiscovery().discover(mcpURL: Higgsfield.mcpEndpoint)
        return try await discovered.client(issuing: tokens).refresh(tokens)
    }

    static func revoke(_ tokens: TokenSet) async throws {
        let discovered = try await OAuthDiscovery().discover(mcpURL: Higgsfield.mcpEndpoint)
        try await discovered.client(issuing: tokens).revoke(tokens)
    }
}

enum ProviderFactory {
    /// The provider for `credential`. Refreshed account tokens go to `persist`, which drops them once
    /// `credential` is no longer the connection's. `unlimitedOptIn` reads the account's Unlimited generations
    /// setting when a job is queued and sent. `constraints` gives the account's cached model constraints, which its
    /// requests keep to.
    static func provider(
        for credential: Credential, persist: @escaping @Sendable (OAuthTokens) async -> Void,
        unlimitedOptIn: @escaping @Sendable () async -> Bool,
        constraints: @escaping @Sendable () async -> ModelConstraintTable
    ) -> any GenerationProvider {
        switch credential {
        case .apiKey(let id, let secret):
            return HiggsfieldAPIProvider(client: HiggsfieldAPIClient(keyID: id, secret: secret))
        case .oauth(let tokens):
            let tokenProvider = TokenProvider(
                tokens: tokens.tokenSet,
                refresh: { try await AccountAuthorization.refresh($0) },
                persist: { await persist(OAuthTokens($0)) })
            let client = MCPClient(endpoint: Higgsfield.mcpEndpoint, tokens: tokenProvider)
            return HiggsfieldMCPProvider(
                account: HiggsfieldAccount(client: client), owner: tokens.owner, unlimitedOptIn: unlimitedOptIn,
                constraints: constraints)
        }
    }
}
