import Foundation
import HiggsfieldMCP
import JutsuCore

public enum AccountSignIn {
    /// A failed account sign-in as the `SignInError` the user is shown; anything but an `OAuthError` stays as it is.
    public static func error(for error: any Error) -> any Error {
        guard let error = error as? OAuthError else { return error }
        switch error {
        case .discoveryFailed: return SignInError.unavailable
        case .unsupportedFlow, .registrationUnavailable, .redirectUnavailable: return SignInError.flowUnavailable
        case .stateMismatch, .issuerMismatch, .invalidCallback: return SignInError.invalidResponse
        case .accessDenied: return SignInError.denied
        case .timedOut: return SignInError.timedOut
        case .reauthenticationRequired: return SignInError.reauthenticationRequired
        case .server(let code, let description): return SignInError.server(description ?? code)
        }
    }
}
