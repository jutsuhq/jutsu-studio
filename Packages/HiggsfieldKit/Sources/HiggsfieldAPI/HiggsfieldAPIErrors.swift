import Foundation
import HiggsfieldCore

/// Maps HTTP answers of the API to `HiggsfieldError`.
enum HiggsfieldAPIErrors {
    /// `nil` for a 2xx status. `retryAfter` is the answer's `Retry-After` header, when it had one.
    static func error(status: Int, body: Data, retryAfter: String? = nil) -> HiggsfieldError? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        // An expired or disabled key is refused with a code of its own; any other 403 is the balance.
        case 403 where code(of: body).map(revokedKeyCodes.contains) == true: return .unauthorized
        case 403: return .insufficientFunds
        // The account's generation queue is full, or an endpoint's own limit was reached: nothing was created or
        // charged, and the same request may be sent again once the wait is over.
        case 429:
            return .concurrencyLimit(retryAfter: seconds(retryAfter) ?? errorBody(body)?.detail?.info?.retryAfter)
        // Queue admission was briefly unavailable: a passing server fault, unlike a model that is disabled.
        case 503 where code(of: body) == "admission_control_unavailable":
            return .server(status: status)
        case 423, 503: return .modelUnavailable
        // The request or model doesn't exist for this account; retrying can't change that.
        case 404: return .validation(field: nil, message: detail(of: body).message)
        case 400, 422:
            let detail = detail(of: body)
            return .validation(field: detail.field, message: detail.message)
        default: return .server(status: status)
        }
    }

    /// `403 {code, detail, expires_at}` of a key that expired or was disabled in the Console.
    static let revokedKeyCodes: Set = ["api_key_expired", "api_key_disabled"]

    /// A `Retry-After` in seconds. The API sends a number; the HTTP-date form isn't read.
    static func seconds(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
            seconds.isFinite, seconds >= 0
        else { return nil }
        return seconds
    }

    /// Reads a FastAPI-style `detail`: a string, a list of `{loc, msg}`, or an object with a `message`.
    /// Falls back to the raw body.
    static func detail(of body: Data) -> (field: String?, message: String) {
        if let parsed = errorBody(body) {
            switch parsed.detail {
            case .text(let text):
                return (nil, text)
            case .items(let items) where !items.isEmpty:
                return (items.first?.field, items.map(\.msg).joined(separator: "; "))
            default:
                if let message = parsed.detail?.info?.message ?? parsed.message ?? parsed.error {
                    return (nil, message)
                }
            }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, text.isEmpty ? "The request was rejected." : text)
    }

    /// The machine-readable `code` of an error, in the `detail` object or next to `detail`.
    static func code(of body: Data) -> String? {
        errorBody(body).flatMap { $0.detail?.info?.code ?? $0.code }
    }

    private static func errorBody(_ body: Data) -> ErrorBody? {
        try? JSONDecoder().decode(ErrorBody.self, from: body)
    }
}

private struct ErrorBody: Decodable {
    var code: String?
    var detail: Detail?
    var message: String?
    var error: String?
}

private enum Detail: Decodable {
    case text(String)
    case items([Item])
    case object(DetailObject)
    case other

    struct Item: Decodable {
        var loc: [LocationPart]?
        var msg: String

        /// `["body", "image_urls", 0]` → `image_urls`: the request parameter the UI can point at.
        var field: String? {
            var keys = (loc ?? []).compactMap(\.key)
            if let first = keys.first, ["body", "query", "path", "header"].contains(first) { keys.removeFirst() }
            return keys.first
        }
    }

    var info: DetailObject? {
        if case .object(let info) = self { info } else { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let items = try? container.decode([Item].self) {
            self = .items(items)
        } else if let info = try? container.decode(DetailObject.self) {
            self = .object(info)
        } else {
            self = .other
        }
    }
}

/// `{code, message, retryable, limit, retry_after_seconds}`, as a full queue (429) or a queue admission outage
/// (503) answers. Every field may be missing.
private struct DetailObject: Decodable {
    var code: String?
    var message: String?
    var retryAfterSeconds: Double?

    var retryAfter: TimeInterval? {
        retryAfterSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    enum CodingKeys: String, CodingKey {
        case code, message
        case retryAfterSeconds = "retry_after_seconds"
    }
}

private enum LocationPart: Decodable {
    case key(String)
    case index(Int)

    var key: String? {
        if case .key(let key) = self { key } else { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let index = try? container.decode(Int.self) {
            self = .index(index)
        } else {
            self = .key(try container.decode(String.self))
        }
    }
}
