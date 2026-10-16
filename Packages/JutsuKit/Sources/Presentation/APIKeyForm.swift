import Foundation
import JutsuCore

/// The "Use an API key" card. Pasted keys often carry a trailing newline, so both fields are trimmed.
public struct APIKeyForm: Sendable, Hashable {
    public var keyID: String
    public var secret: String

    public init(keyID: String = "", secret: String = "") {
        self.keyID = keyID
        self.secret = secret
    }

    public var isComplete: Bool { credential != nil }

    /// `nil` until both fields have something besides whitespace.
    public var credential: Credential? {
        let id = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return .apiKey(id: id, secret: secret)
    }
}
