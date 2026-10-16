import Foundation

/// The account an OpenID Connect `id_token` names, for display and to tell local jobs of accounts apart.
/// The signature is not verified, so nothing may be authorized on these claims. The token comes straight
/// from the token endpoint over TLS.
struct IDTokenClaims: Sendable, Hashable {
    var email: String?
    var name: String?
    var subject: String?
}

extension IDTokenClaims {
    /// `nil` unless `jwt` is a compact JWS whose payload is a JSON object. Missing claims stay `nil`.
    init?(jwt: String) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = Data(base64URLEncoded: String(parts[1])),
            let payload = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue
        else { return nil }
        let text = { (claim: String) in payload[claim]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        email = text("email")
        name = text("name")
        subject = text("sub")
    }
}

extension Data {
    /// Base64url (RFC 4648 §5), with or without `=` padding.
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
