import Foundation

/// The tasks waiting for connectivity or the connection to change (`JobEngine.networkProvider`). Owned and changed
/// only by the engine's actor.
struct NetworkGate {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// `waiter`, known by `token`, is resumed by the next `open`.
    mutating func wait(_ token: UUID, _ waiter: CheckedContinuation<Void, Never>) {
        waiters[token] = waiter
    }

    /// Resumes every waiter; each checks again what it waits for.
    mutating func open() {
        let opened = waiters
        waiters = [:]
        for waiter in opened.values { waiter.resume() }
    }

    /// Resumes the waiter of `token` alone, as its task was cancelled.
    mutating func open(_ token: UUID) {
        waiters.removeValue(forKey: token)?.resume()
    }
}
