import Foundation

/// Waits for the one authorization redirect of a sign-in. Any web page or local process can reach a loopback
/// port, so only a callback carrying the authorization request's `state` counts; others are ignored and
/// waiting goes on. Gives up with `OAuthError.timedOut` once the deadline passes.
final class RedirectWaiter: @unchecked Sendable {  // mutable state is only touched under `lock`
    private let lock = NSLock()
    /// `nil` until `expect(state:)`; callbacks before that are ignored.
    private var expected: String??
    private var received: Result<URL, any Error>?
    private var waiter: CheckedContinuation<URL, any Error>?

    /// Starts accepting callbacks with `state`. `nil` accepts any callback, for a request sent without one.
    func expect(state: String?) {
        lock.withLock { expected = .some(state) }
    }

    /// Hands `callback` to the waiting sign-in when its `state` matches. Returns whether it did.
    @discardableResult
    func offer(_ callback: URL) -> Bool {
        guard accepts(callback) else { return false }
        deliver(.success(callback))
        return true
    }

    func fail(_ error: any Error) {
        deliver(.failure(error))
    }

    /// The accepted callback. Throws `OAuthError.timedOut` after `timeout`, and `CancellationError` when the
    /// task is cancelled.
    func wait(timeout: Duration) async throws -> URL {
        let deadline = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.fail(OAuthError.timedOut)
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let received {
                    lock.unlock()
                    continuation.resume(with: received)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            fail(CancellationError())
        }
    }

    /// Whether `offer` would take `callback`.
    func accepts(_ callback: URL) -> Bool {
        let state = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "state" }?.value
        return lock.withLock {
            guard case .some(let expected) = expected else { return false }
            return expected == nil || state == expected
        }
    }

    /// Keeps the first result; resumes the waiting `wait` if there is one.
    private func deliver(_ result: Result<URL, any Error>) {
        lock.lock()
        guard received == nil else {
            lock.unlock()
            return
        }
        received = result
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }
}
