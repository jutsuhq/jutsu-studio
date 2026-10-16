import Foundation

/// Price of a job. A job is paid in one unit, never mixed. Credits are exact too: an image can cost 0.25 credits.
public enum Cost: Sendable, Hashable {
    case usd(Decimal, isEstimate: Bool)
    case credits(Decimal, isEstimate: Bool)

    public var unit: Capabilities.CostUnit {
        switch self {
        case .usd: .usd
        case .credits: .credits
        }
    }

    public var isEstimate: Bool {
        switch self {
        case .usd(_, let isEstimate), .credits(_, let isEstimate): isEstimate
        }
    }

    /// Dollars or credits, as `unit` says.
    public var amount: Decimal {
        switch self {
        case .usd(let amount, _): amount
        case .credits(let amount, _): amount
        }
    }
}

extension Cost {
    /// The price of each of `parts` jobs that share this one price, in order. Whole credits split as evenly as whole
    /// credits allow, the first parts taking the remainder, so the parts always add up to the whole; a fractional
    /// amount splits evenly. Empty for fewer than 1 part.
    public func split(into parts: Int) -> [Cost] {
        guard parts > 0 else { return [] }
        switch self {
        case .credits(let amount, let isEstimate):
            guard let whole = Int(exactly: NSDecimalNumber(decimal: amount).doubleValue), Decimal(whole) == amount
            else {
                return Array(repeating: .credits(amount / Decimal(parts), isEstimate: isEstimate), count: parts)
            }
            let (share, remainder) = whole.quotientAndRemainder(dividingBy: parts)
            return (0..<parts).map { .credits(Decimal(share + ($0 < remainder ? 1 : 0)), isEstimate: isEstimate) }
        case .usd(let amount, let isEstimate):
            return Array(repeating: .usd(amount / Decimal(parts), isEstimate: isEstimate), count: parts)
        }
    }

    /// This price for `count` jobs of the same request.
    public func times(_ count: Int) -> Cost {
        switch self {
        case .credits(let amount, let isEstimate): .credits(amount * Decimal(count), isEstimate: isEstimate)
        case .usd(let amount, let isEstimate): .usd(amount * Decimal(count), isEstimate: isEstimate)
        }
    }
}

/// Same shape as the synthesized coding, `{"usd":{"_0":"3.816","isEstimate":false}}`, but the amount is a string:
/// on macOS 14 `JSONDecoder` reads JSON numbers through `Double`, so a number amount doesn't round-trip. Whole
/// credits stay a number, as they were when credits were whole only.
extension Cost: Codable {
    private enum CodingKeys: String, CodingKey {
        case usd, credits
    }

    private enum PayloadKeys: String, CodingKey {
        case amount = "_0"
        case isEstimate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.usd) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .usd)
            let isEstimate = try payload.decode(Bool.self, forKey: .isEstimate)
            self = .usd(try Self.decodeAmount(from: payload), isEstimate: isEstimate)
        } else {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .credits)
            self = .credits(
                try Self.decodeAmount(from: payload), isEstimate: try payload.decode(Bool.self, forKey: .isEstimate))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .usd(let amount, let isEstimate):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .usd)
            try payload.encode(amount.description, forKey: .amount)
            try payload.encode(isEstimate, forKey: .isEstimate)
        case .credits(let amount, let isEstimate):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .credits)
            if let whole = Int(exactly: NSDecimalNumber(decimal: amount).doubleValue), Decimal(whole) == amount {
                try payload.encode(whole, forKey: .amount)
            } else {
                try payload.encode(amount.description, forKey: .amount)
            }
            try payload.encode(isEstimate, forKey: .isEstimate)
        }
    }

    /// Libraries saved before the string format hold a JSON number.
    private static func decodeAmount(from payload: KeyedDecodingContainer<PayloadKeys>) throws -> Decimal {
        if let text = try? payload.decode(String.self, forKey: .amount) {
            guard let amount = Decimal(string: text, locale: .posix) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .amount, in: payload, debugDescription: "Not a decimal: \(text)")
            }
            return amount
        }
        let number = try payload.decode(Double.self, forKey: .amount)
        guard let amount = Decimal(shortestOf: number) else {
            throw DecodingError.dataCorruptedError(
                forKey: .amount, in: payload, debugDescription: "Not a finite amount: \(number)")
        }
        return amount
    }
}

extension Locale {
    static let posix = Locale(identifier: "en_US_POSIX")
}

extension Decimal {
    /// Through the shortest decimal string, so 0.318 stays exact; `Decimal(Double)` would not.
    public init?(shortestOf value: Double) {
        guard value.isFinite else { return nil }
        self.init(string: "\(value)", locale: .posix)
    }
}
