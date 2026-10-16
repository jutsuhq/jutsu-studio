import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// SHA-256 for the S256 code challenge. CryptoKit on Apple platforms; tests on Linux inject their own.
public protocol PKCEHasher: Sendable {
    func sha256(_ data: Data) -> Data
}

#if canImport(CryptoKit)
    public struct CryptoKitHasher: PKCEHasher {
        public init() {}

        public func sha256(_ data: Data) -> Data {
            Data(SHA256.hash(data: data))
        }
    }
#endif

/// A PKCE verifier and its S256 challenge (RFC 7636).
struct PKCE: Sendable, Hashable {
    let verifier: String
    let challenge: String

    init(verifier: String = randomURLSafeString(length: 64), hasher: any PKCEHasher) {
        self.verifier = verifier
        self.challenge = hasher.sha256(Data(verifier.utf8)).base64URLEncoded
    }
}

extension Data {
    /// Base64url without padding (RFC 7636 Appendix A).
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Random string over the RFC 3986 unreserved characters; PKCE verifiers allow exactly these.
func randomURLSafeString(length: Int) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return String((0..<length).map { _ in alphabet[Int.random(in: alphabet.indices)] })
}
