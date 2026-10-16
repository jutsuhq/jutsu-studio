import Foundation
import JutsuCore

public enum JobEngineError: Error, Sendable, Hashable {
    case unknownJob(UUID)
    /// No connection, or the connection belongs to another provider or account than the job's.
    case notConnected
    case offline
    /// Once the API starts processing a job it can't be canceled.
    case notCancellable(JobState)
    /// A submit sent with the idempotency key is waiting for its answer; the job can be canceled once queued.
    case submitInProgress
    /// The job would take today's spend over the cap, and the user hasn't agreed to that.
    case overCap
    case notRetryable(JobState)
    case notResumable(JobState)
    /// Run next only reorders jobs still waiting for a slot.
    case notWaiting(JobState)
    /// The download URL answered with a client error (4xx); the engine decides whether waiting can help.
    case downloadFailed(status: Int)
    /// The download was stopped; retrying won't help.
    case downloadRefused(DownloadRefusal)
    /// A submitted job was stored without its request ID.
    case missingRequestID
    /// A bug in the engine: `event` can't happen in `state`.
    case invalidTransition(from: JobState, event: JobEvent)
}

extension JobEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownJob:
            String(localized: "This job is no longer in the queue.", bundle: .module)
        case .notConnected:
            String(
                localized: "Connect the Higgsfield account or API key this job was made with, then try again.",
                bundle: .module)
        case .offline:
            String(localized: "Your Mac is offline. Try again once it is connected.", bundle: .module)
        case .notCancellable:
            String(localized: "Higgsfield is already making this job, so it can't be canceled.", bundle: .module)
        case .notRetryable:
            String(localized: "This job can't be retried.", bundle: .module)
        case .notResumable:
            String(localized: "This job isn't paused.", bundle: .module)
        case .notWaiting:
            String(localized: "Only a job waiting for its turn can run next.", bundle: .module)
        case .downloadFailed(let status):
            String(localized: "The server refused to send the file (HTTP \(status)).", bundle: .module)
        case .downloadRefused(let refusal):
            refusal.message
        case .missingRequestID:
            String(
                localized: "This job was saved without its Higgsfield request, so its result can't be found.",
                bundle: .module)
        case .invalidTransition:
            String(localized: "Internal error.", bundle: .module)
        case .submitInProgress:
            String(
                localized: "Higgsfield may already be starting this job. Cancel it once it shows as queued.",
                bundle: .module)
        case .overCap:
            String(
                localized:
                    "Jobs queued meanwhile took today's spend close to your cap. Try again to confirm going over it.",
                bundle: .module)
        }
    }
}

public enum DownloadRefusal: Sendable, Hashable {
    case notHTTPS
    case tooLarge(maxBytes: Int64)
    /// A partial answer without a usable total size, or one that brought nothing.
    case stalled

    var message: String {
        switch self {
        case .notHTTPS:
            return String(
                localized: "The file isn't on a secure (https) address, so it wasn't downloaded.", bundle: .module)
        case .tooLarge(let maxBytes):
            let limit = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
            return String(localized: "The file is larger than \(limit), so it wasn't downloaded.", bundle: .module)
        case .stalled:
            return String(localized: "The server stopped sending the file. Try again later.", bundle: .module)
        }
    }
}
