import Foundation
import JutsuCore
import Observation

/// Holds the one connection or none. The credential goes only to the vault; the metadata store keeps
/// what the UI shows. Every change of credential is reported through `onCredentialChange`, which the
/// app uses to build the provider and hand it to the engine.
@MainActor
@Observable
public final class ConnectionStore {
    public enum Activity: Sendable, Hashable {
        case idle
        case validatingKey
        /// Sign-in is open in the browser; the page's URL once it is known.
        case signingIn(URL?)

        /// Whether the sign-in sheet is up.
        public var isSigningIn: Bool {
            if case .signingIn = self { true } else { false }
        }
    }

    public private(set) var state: ConnectionState
    public private(set) var activity = Activity.idle
    /// The provider refused the stored credential (401, refresh refused); the user has to sign in again
    /// or replace the key. The connection stays until they do.
    public private(set) var needsAttention = false
    /// The alert to show; the view sets it back to `nil` when dismissed.
    public var alert: UserMessage?

    /// Called with the new credential after every connect and with `nil` after sign-out.
    @ObservationIgnored public var onCredentialChange: @MainActor (Credential?) async -> Void = { _ in }

    @ObservationIgnored private let vault: any CredentialVault
    @ObservationIgnored private let metadata: any ConnectionMetadataStore
    @ObservationIgnored private let services: any ConnectionServices
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    /// Bumped on every start and cancel, so a sign-in that finishes late can't apply its result.
    @ObservationIgnored private var attempt = 0
    /// Bumped whenever the credential changes, so a balance read or token refresh for the previous one can't land.
    @ObservationIgnored private var generation = 0
    /// The revocation started by the last sign-out, for tests to wait on.
    @ObservationIgnored private(set) var revocation: Task<Void, Never>?

    /// Restores the connection from the metadata, provided the vault still holds the credential it describes.
    public init(
        vault: any CredentialVault, metadata: any ConnectionMetadataStore, services: any ConnectionServices
    ) {
        self.vault = vault
        self.metadata = metadata
        self.services = services
        let saved = metadata.load()
        do {
            let credential = try vault.loadCredential()
            if let saved, let credential, credential.matches(saved) {
                state = ConnectionState(saved)
            } else {
                state = .none
                metadata.clear()
            }
        } catch {
            // A locked or failing Keychain says nothing about whether the connection exists; keep the metadata.
            state = .none
            alert = UserMessage(error)
        }
    }

    /// Reports the restored credential once on launch. A Keychain that fails now ends like one failing at `init`:
    /// disconnected, with the metadata kept and an alert.
    public func activate() async {
        guard state.isConnected else { return await onCredentialChange(nil) }
        do {
            await onCredentialChange(try vault.loadCredential())
        } catch {
            state = .none
            alert = UserMessage(error)
            await onCredentialChange(nil)
        }
    }

    // MARK: API key

    public func connectAPIKey(_ form: APIKeyForm) async {
        guard activity == .idle else { return }
        guard case .apiKey(let id, let secret)? = form.credential else {
            alert = .incompleteKey
            return
        }
        activity = .validatingKey
        defer { activity = .idle }
        do {
            guard try await services.validateAPIKey(id: id, secret: secret) else {
                alert = .invalidKey
                return
            }
            try await connect(.apiKey(id: id, secret: secret), as: .apiKey(keyID: id))
        } catch {
            alert = UserMessage(error, kind: .apiKey)
        }
    }

    // MARK: Account

    /// Starts signing in, replacing any sign-in already running. Also used to sign in again while connected.
    @discardableResult
    public func startSignIn() -> Task<Void, Never> {
        signInTask?.cancel()
        attempt += 1
        let current = attempt
        activity = .signingIn(nil)
        let task = Task { await self.signIn(attempt: current) }
        signInTask = task
        return task
    }

    public func cancelSignIn() {
        guard activity.isSigningIn else { return }
        attempt += 1
        signInTask?.cancel()
        signInTask = nil
        activity = .idle
    }

    /// Reuses the client registered by the stored sign-in, if any. A Keychain that can't be read stops before the
    /// browser opens: the new sign-in couldn't be saved either, and registering again would leave another client.
    /// A stored value that doesn't decode is replaced by the new sign-in.
    private func signIn(attempt current: Int) async {
        var previous: OAuthTokens?
        do {
            if case .oauth(let tokens)? = try vault.loadCredential() { previous = tokens }
        } catch is DecodingError {
            previous = nil
        } catch {
            guard current == attempt else { return }
            activity = .idle
            signInTask = nil
            alert = UserMessage(error)
            return
        }
        do {
            let tokens = try await services.signInWithBrowser(reusing: previous) { url in
                await self.show(url, attempt: current)
            }
            guard current == attempt else { return }
            activity = .idle
            signInTask = nil
            try await connect(.oauth(tokens), as: .account(account(signedInWith: tokens)))
        } catch {
            guard current == attempt else { return }
            activity = .idle
            signInTask = nil
            alert = UserMessage(error, kind: .account)
        }
    }

    /// The account the new tokens name. The plan carries over only when it is the same account; credits never
    /// do, since the tokens may name another account without saying so. They are read again on connect.
    private func account(signedInWith tokens: OAuthTokens) -> AccountInfo {
        var account = AccountInfo()
        if case .account(let info) = state { account = info }
        account.credits = nil
        guard tokens.email != nil || tokens.name != nil else { return account }
        if tokens.email != account.email { account = AccountInfo() }
        account.email = tokens.email
        account.name = tokens.name
        return account
    }

    private func show(_ url: URL, attempt current: Int) {
        guard current == attempt else { return }
        activity = .signingIn(url)
    }

    /// Fills in what a provider call learned about the account; plan and e-mail are persisted.
    public func updateAccount(_ info: AccountInfo) {
        guard case .account = state else { return }
        state = .account(info)
        if let saved = state.metadata { metadata.save(saved) }
    }

    /// `ultra` → "Ultra", `creator_plus` → "Creator Plus".
    nonisolated static func planTitle(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Shows the credits `provider` reports for the signed-in account, and its plan when it names one. A
    /// provider that reports no credits, or fails, hides them rather than leave an old number up; the plan
    /// stays, since it rarely changes. An answer that arrives after a sign-out or another sign-in is dropped.
    public func refreshBalance(from provider: any GenerationProvider) async {
        guard case .account = state else { return }
        let current = generation
        var credits: Int?
        var plan: String?
        if case .credits(let amount, let name)? = try? await provider.balance() {
            credits = amount
            plan = name.map(Self.planTitle)
        }
        guard current == generation, case .account(var info) = state else { return }
        info.credits = credits
        if let plan { info.plan = plan }
        updateAccount(info)
    }

    // MARK: Lifecycle

    /// The provider refused the credential. Ignored when not connected.
    public func markNeedsAttention() {
        if state.isConnected { needsAttention = true }
    }

    /// Identifies the current credential for `saveRefreshedTokens`. Read it when building a provider.
    public var credentialGeneration: Int { generation }

    /// Saves tokens refreshed for the credential of `generation`. Writes nothing and returns `false` when the user
    /// has signed out, signed in again or connected otherwise since: a late refresh must not bring old tokens back.
    @discardableResult
    public func saveRefreshedTokens(_ tokens: OAuthTokens, generation tagged: Int) throws -> Bool {
        guard tagged == generation, case .account = state else { return false }
        try vault.saveCredential(.oauth(tokens))
        return true
    }

    /// Deletes the credential and goes back to onboarding. Stays connected if Keychain refuses the delete.
    /// An account's tokens are then revoked in the background; sign-out doesn't wait for it or need the network.
    /// Tokens that can't be read aren't revoked, and the alert says so.
    public func signOut() async {
        cancelSignIn()
        let signedOut: Credential?
        var unreadable = false
        do {
            signedOut = try vault.loadCredential()
        } catch {
            signedOut = nil
            unreadable = true
        }
        do {
            try vault.delete()
        } catch {
            alert = UserMessage(error)
            return
        }
        if unreadable, case .account = state { alert = .notRevoked }
        metadata.clear()
        state = .none
        generation += 1
        needsAttention = false
        if case .oauth(let tokens)? = signedOut {
            revocation = Task { [services] in await services.revoke(tokens) }
        }
        await onCredentialChange(nil)
    }

    private func connect(_ credential: Credential, as newState: ConnectionState) async throws {
        try vault.saveCredential(credential)
        if let saved = newState.metadata { metadata.save(saved) }
        state = newState
        generation += 1
        needsAttention = false
        await onCredentialChange(credential)
    }
}

extension Credential {
    var kind: ProviderKind {
        switch self {
        case .apiKey: .apiKey
        case .oauth: .account
        }
    }

    /// Whether `metadata` describes this credential: the same kind and, where both name one, the same key ID
    /// or e-mail. Keeps a credential written for another connection from showing under this one's name.
    func matches(_ metadata: ConnectionMetadata) -> Bool {
        guard kind == metadata.kind else { return false }
        switch self {
        case .apiKey(let id, _):
            return metadata.displayName == id
        case .oauth(let tokens):
            guard let email = tokens.email, let shown = metadata.displayName else { return true }
            return email == shown
        }
    }
}
