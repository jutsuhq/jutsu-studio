import Foundation
import HiggsfieldCore

/// Maps HTTP answers of the API to `HiggsfieldError`.
enum HiggsfieldAPIErrors {
    /// `nil` for a 2xx status.
    static func error(status: Int, body: Data) -> HiggsfieldError? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403: return .insufficientFunds
        case 423, 503: return .modelUnavailable
        // The request or model doesn't exist for this account; retrying can't change that.
        case 404: return .validation(field: nil, message: detail(of: body).message)
        case 400, 422:
            let detail = detail(of: body)
            return concurrencyLimit(in: detail.message) ?? .validation(field: detail.field, message: detail.message)
        default: return .server(status: status)
        }
    }

    /// The concurrency limit comes back as a 400 with "Maximum number of concurrent requests (N)"
    /// and no Retry-After, so the text is the only signal.
    static func concurrencyLimit(in message: String) -> HiggsfieldError? {
        guard message.contains("Maximum number of concurrent requests") else { return nil }
        let match = message.firstMatch(of: #/Maximum number of concurrent requests \((\d+)\)/#)
        return .concurrencyLimit(max: match.flatMap { Int($0.1) })
    }

    /// Reads a FastAPI-style `detail`: a string, or a list of `{loc, msg}`. Falls back to the raw body.
    static func detail(of body: Data) -> (field: String?, message: String) {
        if let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body) {
            switch parsed.detail {
            case .text(let text):
                return (nil, text)
            case .items(let items) where !items.isEmpty:
                return (items.first?.field, items.map(\.msg).joined(separator: "; "))
            default:
                if let message = parsed.message ?? parsed.error { return (nil, message) }
            }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, text.isEmpty ? "The request was rejected." : text)
    }
}

private struct ErrorBody: Decodable {
    var detail: Detail?
    var message: String?
    var error: String?
}

private enum Detail: Decodable {
    case text(String)
    case items([Item])
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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let items = try? container.decode([Item].self) {
            self = .items(items)
        } else {
            self = .other
        }
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
