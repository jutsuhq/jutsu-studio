import Foundation

public enum RemoteStatus: Sendable, Hashable {
    case queued
    case inProgress
    case completed(videoURL: URL)
    case failed(message: String?)
    /// Refused by content moderation, and not charged.
    case rejected(Rejection)
    case canceled
}

/// The statuses of several submitted jobs from one call (`GenerationProvider.statuses(of:)`).
public struct BatchStatus: Sendable, Hashable {
    /// By `RemoteJob.requestID`. A job missing here is asked for on its own.
    public var statuses: [String: RemoteStatus]
    /// When the provider asks to be polled again, in seconds; `nil` when it doesn't say.
    public var pollAfter: TimeInterval?

    public init(statuses: [String: RemoteStatus], pollAfter: TimeInterval? = nil) {
        self.statuses = statuses
        self.pollAfter = pollAfter
    }
}

/// Why content moderation refused a generation.
public enum Rejection: String, Codable, Sendable, Hashable {
    case explicitContent
    /// A recognizable real person, or a protected character or brand.
    case protectedContent
}
