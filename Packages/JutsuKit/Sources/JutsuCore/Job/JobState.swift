import Foundation

public enum JobState: Codable, Sendable, Hashable {
    case preparing
    case uploading
    case waitingForSlot
    /// Submitted; the API hasn't started it yet.
    case queued
    case processing
    case downloading
    case done
    case failed(reason: FailureReason)
    /// Refused by content moderation (`nsfw`).
    case rejected
    case canceled
    case paused(PauseReason)

    /// Nothing more will happen without the user (retry or a new job).
    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .rejected, .canceled: true
        default: false
        }
    }

    /// Still in the queue, paused jobs included.
    public var isActive: Bool { !isTerminal }

    /// Not yet started by the API, which can't cancel a job once it is processing, or already
    /// generated and only downloading, which is local.
    public var isCancellable: Bool {
        switch self {
        case .preparing, .uploading, .waitingForSlot, .queued, .paused, .downloading: true
        default: false
        }
    }

    /// Not yet submitted, so a user pause keeps it from taking a slot. A connection pause lifts by itself
    /// once the connection is back, so a user pause takes it over; a funds pause already waits for the user.
    public var isPausableByUser: Bool {
        switch self {
        case .preparing, .uploading, .waitingForSlot, .paused(.connectionNeedsAttention): true
        default: false
        }
    }
}

public enum PauseReason: String, Codable, Sendable, Hashable {
    case insufficientFunds
    /// The credential was rejected or removed; the user has to sign in again.
    case connectionNeedsAttention
    /// The provider's price for the uploaded inputs takes today's spend over the cap, and the preliminary
    /// price didn't; resuming agrees to that price.
    case priceAboveCap
    /// The finished, already charged result couldn't be written for lack of disk space. The partial file and the
    /// request stay, so resuming continues the download.
    case notEnoughDiskSpace
    /// A step before submit kept failing for a reason that waiting usually fixes (network, server, model
    /// unavailable), for longer than the engine retries on its own; `Job.retrying` says what with. Nothing is
    /// charged yet; resuming tries again.
    case keptFailing
    /// Pause all; only the user lifts it.
    case byUser
}
