import Foundation

/// Provider failures in terms the engine acts on; each provider maps its transport errors to these.
public enum ProviderError: Error, Sendable, Hashable {
    case unauthorized
    case insufficientFunds
    /// The account is at its limit: nothing started, and the same request can be sent again. `retryAfter` is the
    /// wait the server asked for, in seconds, when it said.
    case concurrencyLimit(retryAfter: TimeInterval?)
    case validation(field: String?, message: String)
    case modelUnavailable
    case server(status: Int)
    case network
    /// Refused by content moderation.
    case rejected
    /// A submit failed after it may have reached the server, and resending it could charge twice.
    case outcomeUnknown
}
