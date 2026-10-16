import Foundation
import JutsuCore

// Transitions, progress, the network gate and slot bookkeeping.
extension JobEngine {
    /// Moves the job through `JobState.transition`, saves it, then publishes it.
    /// An impossible event is a bug: asserts in debug, otherwise logs and fails the job.
    @discardableResult
    func apply(_ event: JobEvent, to id: UUID, _ update: (inout Job) -> Void = { _ in }) async throws -> Job {
        try Task.checkCancellation()
        return try await record(event, to: id, update)
    }

    /// `apply` for a step that already happened, such as a submit the server answered or a result placed in the
    /// output folder: it is written even when the runner was cancelled meanwhile, so the job keeps the paid request
    /// or the file instead of losing track of it.
    @discardableResult
    func record(_ event: JobEvent, to id: UUID, _ update: (inout Job) -> Void = { _ in }) async throws -> Job {
        try await writing(id) {
            guard var job = jobs[id] else { throw JobEngineError.unknownJob(id) }
            guard let next = JobState.transition(job.state, event) else {
                await rejectTransition(event, of: job)
                throw JobEngineError.invalidTransition(from: job.state, event: event)
            }
            let partial = partialDownload(of: id)
            // A new state is a step that got through; the concurrency limit keeps a job waiting for a slot.
            if next != job.state { job.retrying = nil }
            job.state = next
            job.progress = 0
            job.finishedAt = next.isTerminal ? clock.now : nil
            if next.isTerminal { job.downloadFolder = nil }
            update(&job)
            try await repository.save(job)
            jobs[id] = job
            publish(job)
            if next.isTerminal { try? FileManager.default.removeItem(at: partial) }
            return job
        }
    }

    /// Saves a change that keeps the job's state, then publishes it.
    func save(_ id: UUID, _ update: (inout Job) -> Void) async throws {
        try await writing(id) {
            guard var job = jobs[id] else { throw JobEngineError.unknownJob(id) }
            update(&job)
            try await repository.save(job)
            jobs[id] = job
            publish(job)
        }
    }

    /// Runs `body` once no other change of job `id` is being saved. Each change then starts from the last saved
    /// one: two writers that both copied the job before either saved would otherwise drop each other's fields.
    private func writing<T: Sendable>(_ id: UUID, _ body: () async throws -> T) async rethrows -> T {
        while !writeTurns.take(id) {
            await withCheckedContinuation { writeTurns.wait(for: id, $0) }
        }
        defer { writeTurns.end(id) }
        return try await body()
    }

    private func rejectTransition(_ event: JobEvent, of job: Job) async {
        assertionFailure("Job \(job.id): \(event) can't happen in \(job.state)")
        // The states can hold a failure's text, with paths or server words in it.
        log.fault("Job \(job.id): impossible transition", detail: "\(event) in \(job.state)")
        guard
            let failed = JobState.transition(job.state, .failed(reason: .internalError))
        else { return }
        var job = job
        job.state = failed
        job.finishedAt = clock.now
        do {
            try await repository.save(job)
        } catch {
            log.error("Job \(job.id): saving failed", detail: String(describing: error))
        }
        jobs[job.id] = job
        publish(job)
    }

    /// Progress isn't saved: it only matters while the app runs. Small steps are kept in `jobs` without an
    /// event (`ProgressCoalescer`); the next published change of the job carries them.
    func report(progress: Double, of id: UUID, in state: JobState) {
        guard var job = jobs[id], job.state == state else { return }
        job.progress = progress
        jobs[id] = job
        if progressCoalescer.shouldPublish(id, progress: progress, at: clock.now) { publish(job) }
    }

    /// Sends `job` to `events`. Every change goes through here so progress coalescing knows what the UI has.
    func publish(_ job: Job) {
        if job.state.isTerminal {
            progressCoalescer.forget(job.id)
        } else {
            progressCoalescer.didPublish(job.id, progress: job.progress, at: clock.now)
        }
        eventSink.yield(job)
    }

    /// The provider to use for `job` right now, without waiting.
    func currentProvider(for job: Job) throws -> any GenerationProvider {
        guard isOnline else { throw JobEngineError.offline }
        guard let provider, provider.owns(job), !connectionNeedsAttention else {
            throw JobEngineError.notConnected
        }
        return provider
    }

    /// Waits until the network and the job's connection are usable. An unsubmitted job without a
    /// usable connection throws `notConnected` so it pauses; a submitted one waits for the connection.
    func networkProvider(for job: Job) async throws -> any GenerationProvider {
        while true {
            try Task.checkCancellation()
            if isOnline {
                if let provider, provider.owns(job), !connectionNeedsAttention { return provider }
                if job.state.isBeforeSubmit { throw JobEngineError.notConnected }
            }
            await waitForGate()
        }
    }

    func waitUntilOnline() async throws {
        while !isOnline {
            try Task.checkCancellation()
            await waitForGate()
        }
        try Task.checkCancellation()
    }

    /// Returns when connectivity or the connection changes, or when the task is canceled.
    private func waitForGate() async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    gate.wait(token, continuation)
                }
            }
        } onCancel: {
            Task { await self.openGate(token) }
        }
    }

    private func openGate(_ token: UUID) {
        gate.open(token)
    }

    func acquireSlot(_ id: UUID) async throws {
        guard !slotHolders.contains(id) else { return }
        let job = try await loadJob(id)
        try await limiter.acquire(id, order: SlotOrder(queuedAt: job.createdAt, promotedAt: job.promotedAt))
        slotHolders.insert(id)
    }

    func occupySlot(_ id: UUID) async {
        guard !slotHolders.contains(id) else { return }
        await limiter.occupy()
        slotHolders.insert(id)
    }

    func releaseSlot(_ id: UUID) async {
        guard slotHolders.remove(id) != nil else { return }
        await limiter.release()
    }
}
