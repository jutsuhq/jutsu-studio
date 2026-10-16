import Foundation

/// Provider failures in terms the engine acts on; each provider maps its transport errors to these.
public enum ProviderError: Error, Sendable, Hashable {
    case unauthorized
    case insufficientFunds
    /// All slots busy. `max` is the limit the API reported, when it did.
    case concurrencyLimit(max: Int?)
    case validation(field: String?, message: String)
    case modelUnavailable
    case server(status: Int)
    case network
    /// Refused by content moderation.
    case rejected
    /// A submit failed after it may have reached the server, and resending it could charge twice.
    case outcomeUnknown
}
