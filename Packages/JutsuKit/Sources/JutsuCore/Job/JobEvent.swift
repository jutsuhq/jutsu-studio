import Foundation

/// Something that happened to a job: a pipeline step finished, the API answered, or the user acted.
public enum JobEvent: Sendable, Hashable {
    case prepared
    case uploaded
    /// The API accepted the job and returned a request ID.
    case submitted
    /// Submit was refused because all of the account's slots are busy.
    case hitConcurrencyLimit
    case started
    case completed
    case downloaded
    case failed(reason: FailureReason)
    case rejected
    case paused(PauseReason)
    case cancel
    case resume
    case retry
    /// The user asks for the result of a generation that already finished, without generating again.
    case retryDownload
    /// The user asks to poll a generation that failed at the deadline again; the provider may still finish it.
    case checkAgain
}
