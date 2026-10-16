import Foundation
import JutsuCore

/// An alert: short title, one sentence of detail, and where to go next (FEATURES §4.5).
public struct UserMessage: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        case openSettings
        case openConsole
    }

    public var title: String
    public var message: String
    public var action: Action?

    public var id: String { title + "\n" + message }

    public init(title: String, message: String, action: Action? = nil) {
        self.title = title
        self.message = message
        self.action = action
    }

    public static let incompleteKey = UserMessage(
        title: String(localized: "Enter both the key ID and the secret", bundle: .module),
        message: String(localized: "You find both in the Higgsfield console.", bundle: .module))
    public static let invalidKey = UserMessage(
        title: String(localized: "Key is invalid", bundle: .module),
        message: String(
            localized: "Higgsfield refused this key ID and secret. Check both and try again.", bundle: .module),
        action: .openConsole)
    public static let notRevoked = UserMessage(
        title: String(localized: "Signed out on this Mac only", bundle: .module),
        message: String(
            localized: """
                Jutsu Studio couldn't read the sign-in to revoke it, \
                so it stays valid on Higgsfield until it expires.
                """, bundle: .module))

    /// The message for `error`, or `nil` when the user shouldn't see one (they canceled, or the engine
    /// handles it silently). `kind` is the connection the error came from, when known.
    public init?(_ error: any Error, kind: ProviderKind? = nil) {
        switch error {
        case is CancellationError:
            return nil
        case let error as ProviderError:
            guard let message = Self.provider(error, kind: kind) else { return nil }
            self = message
        case let error as SignInError:
            self = Self.signIn(error)
        case let error as MediaLinkError:
            self.init(error)
        case let reason as FailureReason:
            self = UserMessage(title: String(localized: "Something went wrong", bundle: .module), message: reason.text)
        default:
            self = UserMessage(
                title: String(localized: "Something went wrong", bundle: .module), message: error.localizedDescription)
        }
    }

    private static func provider(_ error: ProviderError, kind: ProviderKind?) -> UserMessage? {
        switch error {
        case .unauthorized:
            return kind == .account
                ? UserMessage(
                    title: String(localized: "Sign in again", bundle: .module),
                    message: String(localized: "Your Higgsfield sign-in has expired.", bundle: .module),
                    action: .openSettings)
                : UserMessage(
                    title: String(localized: "API key is invalid", bundle: .module),
                    message: String(localized: "Higgsfield refused the key. Check it in Settings.", bundle: .module),
                    action: .openSettings)
        case .insufficientFunds:
            return kind == .account
                ? UserMessage(
                    title: String(localized: "Not enough credits", bundle: .module),
                    message: String(localized: "Your plan has no credits left for this job.", bundle: .module))
                : UserMessage(
                    title: String(localized: "Not enough balance", bundle: .module),
                    message: String(localized: "Top up your API balance in the Higgsfield console.", bundle: .module),
                    action: .openConsole)
        case .concurrencyLimit:
            return nil
        case .validation(let field, let message):
            return UserMessage(
                title: String(localized: "Higgsfield refused the request", bundle: .module),
                message: field.map { "\($0): \(message)" } ?? message)
        case .modelUnavailable:
            return UserMessage(
                title: String(localized: "Model temporarily unavailable", bundle: .module),
                message: String(localized: "Jutsu Studio tries again later by itself.", bundle: .module))
        case .server(let status):
            return UserMessage(
                title: String(localized: "Higgsfield is having trouble", bundle: .module),
                message: String(
                    localized: "The server answered \(status). Try again in a few minutes.", bundle: .module))
        case .network:
            return UserMessage(
                title: String(localized: "Can't reach Higgsfield", bundle: .module),
                message: String(localized: "Check your internet connection and try again.", bundle: .module))
        case .rejected:
            return UserMessage(
                title: String(localized: "Rejected by content moderation", bundle: .module),
                message: String(localized: "You were not charged.", bundle: .module))
        case .outcomeUnknown:
            return UserMessage(
                title: String(localized: "The job may have started", bundle: .module),
                message: String(
                    localized: "Check your generations on Higgsfield before trying again, or it may be charged twice.",
                    bundle: .module))
        }
    }

    private static func signIn(_ error: SignInError) -> UserMessage {
        switch error {
        case .unavailable:
            UserMessage(
                title: String(localized: "Sign-in isn't available right now", bundle: .module),
                message: String(
                    localized:
                        "Higgsfield's sign-in server didn't answer as expected. Try again later or use an API key.",
                    bundle: .module))
        case .flowUnavailable:
            UserMessage(
                title: String(localized: "This sign-in method isn't available", bundle: .module),
                message: String(
                    localized: "Higgsfield didn't accept Jutsu Studio's sign-in. Connect with an API key instead.",
                    bundle: .module))
        case .denied:
            UserMessage(
                title: String(localized: "Access was denied", bundle: .module),
                message: String(localized: "Jutsu Studio wasn't allowed to use your account.", bundle: .module))
        case .timedOut:
            UserMessage(
                title: String(localized: "Sign-in timed out", bundle: .module),
                message: String(
                    localized: "Jutsu Studio stopped waiting for the browser. Try signing in again.", bundle: .module))
        case .invalidResponse:
            UserMessage(
                title: String(localized: "Sign-in failed", bundle: .module),
                message: String(localized: "Higgsfield's answer didn't check out. Try again.", bundle: .module))
        case .reauthenticationRequired:
            UserMessage(
                title: String(localized: "Sign in again", bundle: .module),
                message: String(localized: "Your Higgsfield sign-in has expired.", bundle: .module),
                action: .openSettings)
        case .server(let description):
            UserMessage(
                title: String(localized: "Sign-in failed", bundle: .module),
                message: description ?? String(localized: "Higgsfield refused the sign-in.", bundle: .module))
        }
    }
}

/// The confirmation shown before the connection is deleted.
public struct SignOutConfirmation: Sendable, Hashable {
    public var title: String
    public var message: String
    public var confirmTitle: String

    /// `nil` when there is nothing to sign out of.
    public init?(_ state: ConnectionState) {
        let consequence = String(localized: "Queued jobs pause until you connect again.", bundle: .module)
        switch state {
        case .none:
            return nil
        case .apiKey:
            title = String(localized: "Remove the API key?", bundle: .module)
            message = String(localized: "The key is deleted from macOS Keychain. \(consequence)", bundle: .module)
            confirmTitle = String(localized: "Remove", bundle: .module)
        case .account:
            title = String(localized: "Sign out of Higgsfield?", bundle: .module)
            message = String(localized: "Your sign-in is deleted from macOS Keychain. \(consequence)", bundle: .module)
            confirmTitle = String(localized: "Sign Out", bundle: .module)
        }
    }
}
