import CryptoKit
import Foundation

/// The digest that tells a retry of a request from another request under the same `request_id`: SHA-256 of the
/// value as JSON with sorted keys, so the same parameters always give the same digest.
public enum AgentFingerprint {
    public static func of(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
