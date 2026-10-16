import Foundation

/// The engine's submits in flight, as quitting sees them (`JobEngine.stop(finishingSubmitsWithin:)`): the jobs whose
/// submit is being sent or waits for its answer, whether the engine is stopping so that no new one starts, and the
/// `stop` waiting for the ones out to be answered. Owned and changed only by the engine's actor.
struct SubmitTracker {
    /// Jobs whose submit is being sent or waits for its answer.
    private(set) var inFlight: Set<UUID> = []
    /// Set while `stop` gives submits in flight their time; `begin` refuses meanwhile.
    var isStopping = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    /// Records that job `id` sends its submit; `false`, recording nothing, while stopping.
    mutating func begin(_ id: UUID) -> Bool {
        guard !isStopping else { return false }
        inFlight.insert(id)
        return true
    }

    /// Ends the submit of job `id` started with `begin`; once none is out, the waiters are resumed.
    mutating func finish(_ id: UUID) {
        inFlight.remove(id)
        if inFlight.isEmpty { releaseWaiters() }
    }

    /// `waiter` is resumed once no submit is out (at once when none is), or by `releaseWaiters`.
    mutating func wait(_ waiter: CheckedContinuation<Void, Never>) {
        guard !inFlight.isEmpty else { return waiter.resume() }
        waiters.append(waiter)
    }

    /// Resumes every waiter, as when their time is up. Returns whether any was waiting.
    @discardableResult
    mutating func releaseWaiters() -> Bool {
        guard !waiters.isEmpty else { return false }
        let released = waiters
        waiters = []
        for waiter in released { waiter.resume() }
        return true
    }
}
