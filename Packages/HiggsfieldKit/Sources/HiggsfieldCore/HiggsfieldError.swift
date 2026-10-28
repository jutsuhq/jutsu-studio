import Foundation

/// A failed call to either Higgsfield connection, in terms a caller can act on.
public enum HiggsfieldError: Error, Sendable, Hashable {
    /// The credential was refused: a wrong or revoked API key, or a sign-in that can't be refreshed.
    case unauthorized
    case insufficientFunds
    /// The account is at its limit (a full generation queue, `429`): nothing was created or charged, and the same
    /// request can be sent again. `retryAfter` is the wait the server asked for, in seconds, when it said.
    case concurrencyLimit(retryAfter: TimeInterval?)
    /// The request was refused as it is; `field` names the offending parameter when the server did.
    case validation(field: String?, message: String)
    case modelUnavailable
    /// The account connection doesn't offer a tool this call needs, by name and arguments.
    case toolUnavailable(String)
    /// An answer of this status the client can't read or act on, including an unreadable 2xx body.
    case server(status: Int)
    /// The request never got an HTTP answer.
    case network
    /// A paid call failed before its request went out (the session, the token or the tool list): nothing started,
    /// so it can be sent again.
    case notSent
}

/// A generation as the server reports it.
public enum GenerationStatus: Sendable, Hashable {
    case queued
    case inProgress
    case completed(videoURL: URL)
    case failed(message: String?)
    /// Refused by content moderation, and not charged.
    case rejected(Moderation)
    case canceled
}

/// An image generation as the server reports it: like `GenerationStatus`, but it finishes with several images.
public enum ImageStatus: Sendable, Hashable {
    case queued
    case inProgress
    /// Every https image URL of the answer, in its order; never empty.
    case completed(imageURLs: [URL])
    case failed(message: String?)
    case rejected(Moderation)
    case canceled
}

/// Why moderation refused a generation, by the status the server reported.
public enum Moderation: String, Sendable, Hashable {
    /// `nsfw`: explicit content.
    case explicitContent = "nsfw"
    /// `ip_detected`: a recognizable real person, or a protected character or brand.
    case protectedContent = "ip_detected"
}
