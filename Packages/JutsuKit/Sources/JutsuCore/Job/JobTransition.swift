import Foundation

extension JobState {
    /// The job's lifecycle. Returns `nil` when `event` can't happen in `state`; callers treat that as a bug.
    public static func transition(_ state: JobState, _ event: JobEvent) -> JobState? {
        switch (state, event) {
        case (.preparing, .prepared): .uploading
        case (.uploading, .uploaded): .waitingForSlot
        case (.waitingForSlot, .submitted): .queued
        case (.waitingForSlot, .hitConcurrencyLimit): .waitingForSlot
        case (.queued, .started): .processing
        // A poll can miss `in_progress` entirely.
        case (.queued, .completed), (.processing, .completed): .downloading
        case (.downloading, .downloaded): .done
        case (.queued, .rejected), (.processing, .rejected): .rejected
        case (_, .paused(.byUser)) where state.isPausableByUser: .paused(.byUser)
        // Only before submit: a job the API has accepted keeps its state, the engine just stops polling.
        case (.preparing, .paused(let reason)), (.uploading, .paused(let reason)),
            (.waitingForSlot, .paused(let reason)):
            reason == .notEnoughDiskSpace ? nil : .paused(reason)
        // A full disk only pauses the download of a paid result, and resuming continues it.
        case (.downloading, .paused(.notEnoughDiskSpace)): .paused(.notEnoughDiskSpace)
        case (.paused(.notEnoughDiskSpace), .resume): .downloading
        // Restart the pipeline; prepared files and uploads are cached by content hash, so this is cheap.
        case (.paused, .resume): .preparing
        case (.failed, .retry), (.canceled, .retry): .preparing
        case (.failed, .retryDownload), (.canceled, .retryDownload): .downloading
        case (.failed, .checkAgain): .queued
        case (_, .cancel) where state.isCancellable: .canceled
        case (.paused, .failed): nil
        case (_, .failed(let reason)) where state.isActive: .failed(reason: reason)
        default: nil
        }
    }
}
