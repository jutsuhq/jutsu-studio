import Foundation
import JutsuCore

// What a failed step does to its job: retry with backoff, pause, or fail.
extension JobEngine {
    /// Maps a failed step to the job's next state. Returns `false` when the runner should stop.
    func recover(from error: any Error, of id: UUID, delay: inout Backoff) async -> Bool {
        guard !Task.isCancelled, !(error is CancellationError), let job = jobs[id] else { return false }
        do {
            switch error {
            case let error as ProviderError:
                try await recover(from: error, job: job, delay: &delay)
            case JobEngineError.invalidTransition:
                return false
            case JobEngineError.notConnected where job.state.isBeforeSubmit:
                try await apply(.paused(.connectionNeedsAttention), to: id)
            case _ where Self.isOutOfSpace(error) && job.state == .downloading:
                // The result is paid for: the partial file and the request stay, so resuming continues the download.
                log.error("Job \(id): not enough disk space for the result", detail: String(describing: error))
                try await apply(.paused(.notEnoughDiskSpace), to: id)
            case let reason as FailureReason:
                try await apply(.failed(reason: reason), to: id)
            default:
                log.error("Job \(id) failed", detail: String(describing: error))
                try await apply(.failed(reason: Self.failureReason(for: error)), to: id)
            }
            return true
        } catch {
            if !(error is CancellationError) {
                log.error("Job \(id): can't record the error", detail: String(describing: error))
            }
            return false
        }
    }

    private func recover(from error: ProviderError, job: Job, delay: inout Backoff) async throws {
        switch error {
        case .network:
            try await retry(job.id, after: .network, delay: &delay)
        case .server(let status):
            try await retry(job.id, after: .server(status: status), delay: &delay)
        case .modelUnavailable:
            try await retry(job.id, after: .modelUnavailable, delay: &delay)
        case .concurrencyLimit(let retryAfter):
            await releaseSlot(job.id)
            if job.state == .waitingForSlot { try await apply(.hitConcurrencyLimit, to: job.id) }
            try await retry(job.id, after: .concurrencyLimit, delay: &delay, serverWait: retryAfter)
        case .unauthorized:
            // Submitted jobs keep their state and wait in `networkProvider` for the connection.
            if !connectionNeedsAttention { await connectionAttentionHandler?() }
            connectionNeedsAttention = true
            if job.state.isBeforeSubmit { try await apply(.paused(.connectionNeedsAttention), to: job.id) }
        case .insufficientFunds:
            if job.state.isBeforeSubmit {
                try await apply(.paused(.insufficientFunds), to: job.id)
            } else {
                try await retry(job.id, after: .insufficientFunds, delay: &delay)
            }
        case .validation(_, let message):
            try await apply(.failed(reason: .message(message)), to: job.id)
        case .outcomeUnknown:
            try await apply(.failed(reason: .outcomeUnknown), to: job.id)
        case .rejected:
            let accepted = job.state == .queued || job.state == .processing
            try await apply(accepted ? .rejected : .failed(reason: .contentModeration), to: job.id)
        }
    }

    /// Waits before the failed step runs again, with the wait and the failure on the job (`Job.retrying`) so its
    /// row shows them. Waiting can't fix everything: a job not yet submitted that kept failing past the engine's
    /// patience pauses as `keptFailing`, nothing charged, until the user resumes it; a busy account (concurrency
    /// limit) is waited for. A submitted job is never paused or resubmitted for it: it may still finish and be
    /// charged, so it retries until its generation deadline, as polling does, and a download until it succeeds.
    /// `serverWait` is the wait the server asked for (`Retry-After`), kept in `serverRetryDelay`; jitter only
    /// lengthens it, within that range. Without it the wait is `delay`'s.
    private func retry(
        _ id: UUID, after cause: RetryStatus.Cause, delay: inout Backoff, serverWait: TimeInterval? = nil
    ) async throws {
        guard let job = jobs[id] else { throw JobEngineError.unknownJob(id) }
        log.error("Job \(id): retrying", detail: String(describing: cause))
        let now = clock.now
        if job.retrying == nil { delay.reset() }
        let failures = (job.retrying?.failures ?? 0) + 1
        let since = job.retrying?.since ?? now
        if job.state.isQueuedOrProcessing, isPastDeadline(job) {
            try await failAtDeadline(id)
            return
        }
        if job.state.isBeforeSubmit, cause != .concurrencyLimit, failures >= settings.retryPauseFailures,
            now.timeIntervalSince(since) >= settings.retryPauseAfter
        {
            log.error("Job \(id): kept failing for \(Int(now.timeIntervalSince(since))) s, pausing")
            try await apply(.paused(.keptFailing), to: id) {
                $0.retrying = RetryStatus(failures: failures, since: since, nextAttemptAt: now, cause: cause)
            }
            return
        }
        let wait =
            serverWait.map {
                let range = settings.serverRetryDelay
                let asked = min(max($0, range.lowerBound), range.upperBound)
                return min(asked * (1 + .random(in: 0...settings.jitter)), range.upperBound)
            } ?? delay.next()
        try await save(id) {
            $0.retrying = RetryStatus(
                failures: failures, since: since, nextAttemptAt: now.addingTimeInterval(wait), cause: cause)
        }
        try await clock.sleep(for: wait)
    }

    /// Whether a submitted job is past its generation deadline, which counts from submit or the last check again.
    private func isPastDeadline(_ job: Job) -> Bool {
        guard let started = job.checkedAgainAt ?? job.submittedAt else { return false }
        return clock.now.timeIntervalSince(started) >= settings.generationDeadline
    }

    /// Fails a submitted job without a result by its deadline. Its request stays, so it can be checked again.
    func failAtDeadline(_ id: UUID) async throws {
        log.error("Job \(id): no result within the deadline")
        await releaseSlot(id)
        try await apply(.failed(reason: .deadline), to: id) { $0.timedOutAt = clock.now }
    }
}
