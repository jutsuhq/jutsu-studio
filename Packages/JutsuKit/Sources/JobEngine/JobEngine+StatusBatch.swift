import Foundation
import JutsuCore

// Polling the jobs of a connection that reads several statuses in one call (`GenerationProvider.statuses(of:)`).
// Each job's task still drives its own state; instead of sleeping and asking for its status, it waits for the next
// shared call, which one ticker task makes for every waiting job at once, in groups of `statusBatchLimit`.
extension JobEngine {
    /// Whether `job` waits for the shared status call: it was submitted with the active connection, and that one
    /// reads several statuses at once.
    func pollsInBatch(_ job: Job) -> Bool {
        guard let provider, job.remote != nil, provider.statusBatchLimit > 1 else { return false }
        return provider.owns(job)
    }

    /// Waits for the next shared status call and returns what it said about job `id`. A canceled task stops
    /// waiting at once, even while the call is still out.
    func batchedStatus(of id: UUID) async throws -> BatchedStatus {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                statusBatch.wait(id, continuation)
                startStatusTicker()
            }
        } onCancel: {
            Task { await self.dropStatusWaiter(id) }
        }
    }

    private func dropStatusWaiter(_ id: UUID) {
        statusBatch.drop(id)
    }

    private func startStatusTicker() {
        guard statusBatch.ticker == nil else { return }
        statusBatch.ticker = Task { await self.tickStatuses() }
    }

    /// While jobs poll through it: sleeps as long as `StatusPace` says, then answers every waiting job from one call
    /// per group.
    private func tickStatuses() async {
        var pace = StatusPace(settings)
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: pace.delay)
            } catch {
                break
            }
            if statusBatch.isEmpty {
                // Jobs still handling the last answer join the next call; without any, the ticker ends.
                guard hasBatchPolledRunners else { break }
                continue
            }
            let waiting = statusBatch.waiting
            let (answers, pollAfter) = await statuses(of: waiting)
            guard !Task.isCancelled else { break }
            statusBatch.answer(waiting, with: answers)
            pace.update(answers: answers, pollAfter: pollAfter)
        }
        if !Task.isCancelled { statusBatch.ticker = nil }
    }

    /// Whether any job's task polls through the shared call, though it may not be waiting for it right now.
    private var hasBatchPolledRunners: Bool {
        jobs.values.contains { $0.state.isQueuedOrProcessing && runners[$0.id] != nil && pollsInBatch($0) }
    }

    /// One call per group of up to `statusBatchLimit` jobs, oldest first. Jobs of another connection, groups the
    /// provider couldn't answer and jobs missing from an answer get no entry. `pollAfter` is the shortest wait asked.
    private func statuses(of ids: [UUID]) async -> (answers: [UUID: BatchedStatus], pollAfter: TimeInterval?) {
        guard let provider else { return ([:], nil) }
        let polled = ids.compactMap { jobs[$0] }.filter { provider.owns($0) && $0.remote != nil }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var answers: [UUID: BatchedStatus] = [:]
        var pollAfter: TimeInterval?
        for group in StatusBatch.groups(polled, of: provider.statusBatchLimit) {
            let batch: BatchStatus?
            do {
                batch = try await provider.statuses(of: group.compactMap(\.remote))
            } catch is CancellationError {
                break
            } catch {
                log.error("Shared status call failed, polling each job", detail: String(describing: error))
                batch = nil
            }
            guard let batch else { continue }
            if let asked = batch.pollAfter { pollAfter = min(pollAfter ?? asked, asked) }
            for job in group {
                if let requestID = job.remote?.requestID, let status = batch.statuses[requestID] {
                    answers[job.id] = .status(status)
                }
            }
        }
        return (answers, pollAfter)
    }
}
