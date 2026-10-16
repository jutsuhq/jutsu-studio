import Foundation
import JutsuCore

/// The one connection the app has, as the UI shows it. Never carries a secret.
public enum ConnectionState: Sendable, Hashable {
    case none
    case apiKey(keyID: String)
    case account(AccountInfo)

    public var kind: ProviderKind? {
        switch self {
        case .none: nil
        case .apiKey: .apiKey
        case .account: .account
        }
    }

    public var isConnected: Bool { self != .none }

    /// Rebuilds the state from what was persisted at connect time.
    init(_ metadata: ConnectionMetadata?) {
        switch metadata?.kind {
        case nil: self = .none
        case .apiKey: self = .apiKey(keyID: metadata?.displayName ?? "")
        case .account:
            self = .account(AccountInfo(email: metadata?.displayName, name: metadata?.name, plan: metadata?.plan))
        }
    }

    var metadata: ConnectionMetadata? {
        switch self {
        case .none: nil
        case .apiKey(let keyID): ConnectionMetadata(kind: .apiKey, displayName: keyID, plan: nil)
        case .account(let info):
            ConnectionMetadata(kind: .account, displayName: info.email, plan: info.plan, name: info.name)
        }
    }
}

/// What is known about a signed-in Higgsfield account. E-mail and name come from the sign-in's
/// `id_token` when the server sends one; plan and credits stay `nil` until a provider call fills them in.
public struct AccountInfo: Sendable, Hashable {
    public var email: String?
    public var name: String?
    public var plan: String?
    /// Not persisted: credits change with every job.
    public var credits: Int?

    public init(email: String? = nil, name: String? = nil, plan: String? = nil, credits: Int? = nil) {
        self.email = email
        self.name = name
        self.plan = plan
        self.credits = credits
    }
}

/// The non-secret part of a connection, kept in `UserDefaults` so the UI can show it without Keychain.
public struct ConnectionMetadata: Codable, Sendable, Hashable {
    public var kind: ProviderKind
    /// Key ID for an API key, e-mail for an account.
    public var displayName: String?
    public var plan: String?
    /// The account holder's name; `nil` for an API key.
    public var name: String?

    public init(kind: ProviderKind, displayName: String?, plan: String?, name: String? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.plan = plan
        self.name = name
    }
}
