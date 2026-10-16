import Foundation

/// The warning in the menu bar and the sidebar when a signed-in account runs low on credits.
public enum LowCreditWarning {
    /// "Low credits: 42 left" when the account's credits are known and below `threshold`. `nil` for an API key,
    /// whose balance the app can't read, and while the credits are unknown.
    public static func text(for connection: ConnectionState, threshold: Int, locale: Locale = .current) -> String? {
        guard case .account(let info) = connection, let credits = info.credits, credits < threshold else { return nil }
        return String(
            localized: "Low credits: \(ConnectionState.grouped(credits, locale: locale)) left", bundle: .module)
    }
}
