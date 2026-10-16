import Foundation
import JutsuCore

/// Where the credential lives. The app adapts `KeychainStore.activeConnection` to this;
/// the signatures match `SecretStore` so the adapter only forwards.
public protocol CredentialVault: Sendable {
    func saveData(_ data: Data) throws
    func loadData() throws -> Data?
    /// Deleting when nothing is stored is not an error.
    func delete() throws
}

extension CredentialVault {
    public func saveCredential(_ credential: Credential) throws {
        try saveData(JSONEncoder().encode(credential))
    }

    public func loadCredential() throws -> Credential? {
        guard let data = try loadData() else { return nil }
        return try JSONDecoder().decode(Credential.self, from: data)
    }
}

/// Persists `ConnectionMetadata`. Only used from the main actor.
public protocol ConnectionMetadataStore {
    func load() -> ConnectionMetadata?
    func save(_ metadata: ConnectionMetadata)
    func clear()
}

/// `ConnectionMetadataStore` on `UserDefaults`, as JSON under one key.
public struct UserDefaultsMetadataStore: ConnectionMetadataStore {
    public static let key = "connection.metadata"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ConnectionMetadata? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ConnectionMetadata.self, from: data)
    }

    public func save(_ metadata: ConnectionMetadata) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// The network side of connecting. The app implements it with `HiggsfieldAPI` and `HiggsfieldMCP`
/// and maps OAuth failures to `SignInError` with `AccountSignIn.error(for:)`, so this module never imports either.
public protocol ConnectionServices: Sendable {
    /// `false` when the key was refused; other failures throw.
    func validateAPIKey(id: String, secret: String) async throws -> Bool
    /// OAuth with PKCE in the default browser. Calls `show` with the sign-in page once it is known, so the user
    /// can open it again or copy it when the browser didn't come up. Throws `CancellationError` when the task is
    /// cancelled. `previous` is the stored sign-in, whose registered client ID can be reused.
    func signInWithBrowser(
        reusing previous: OAuthTokens?, show: @escaping @Sendable (URL) async -> Void
    ) async throws -> OAuthTokens
    /// Revokes `tokens` at the server that issued them. Best effort: failures, offline included, are ignored.
    func revoke(_ tokens: OAuthTokens) async
}
