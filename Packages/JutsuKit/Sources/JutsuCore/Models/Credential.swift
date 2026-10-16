import Foundation

/// The secret for the active connection. Stored only in Keychain by the `Secrets` module.
public enum Credential: Codable, Sendable, Hashable {
    case apiKey(id: String, secret: String)
    case oauth(OAuthTokens)
}

extension Credential: CustomStringConvertible {
    public var description: String {
        switch self {
        case .apiKey(let id, _): "Credential.apiKey(id: \(id), secret: <redacted>)"
        case .oauth(let tokens): "Credential.oauth(\(tokens))"
        }
    }
}
