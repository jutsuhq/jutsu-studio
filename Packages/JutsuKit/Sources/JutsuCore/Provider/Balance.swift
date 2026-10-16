import Foundation

public enum Balance: Sendable, Hashable {
    case usd(Decimal)
    /// `plan` is the subscription the credits come with, as the provider names it.
    case credits(Int, plan: String? = nil)
}
