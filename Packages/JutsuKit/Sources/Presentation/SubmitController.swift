import Foundation
import JutsuCore
import Observation

/// One screen's submits: the busy flag, the over-cap question and the approved enqueue that follows it, the same on
/// every screen that queues jobs. Each submit runs in a task of its own, never in a view's `.task`: enqueues are
/// user-initiated engine work and run on after the user leaves the screen, so nothing cancels one halfway through.
@MainActor
@Observable
public final class SubmitController {
    /// A submit waiting for the user to agree to go over today's cap.
    public struct Pending: Identifiable {
        public let id = UUID()
        public let confirmation: CapConfirmation
        fileprivate let approve: @MainActor () async -> Void
    }

    /// The question while it is up; dismissing the dialog clears it.
    public var pending: Pending?
    private var running = 0

    public init() {}

    /// A submit is running: from the click until its jobs are queued, it is blocked or the question is up.
    public var isBusy: Bool { running > 0 }

    /// Runs `submit` in a task of its own, unless one is running. The flag is set before the
    /// first `await`, so a second click (or ⌘↩) that arrives while today's spend is read is dropped instead of queueing
    /// the jobs again.
    /// - Returns: the submit's task; `nil` when it was dropped.
    @discardableResult
    public func run(_ submit: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard running == 0 else { return nil }
        running += 1
        return Task {
            defer { running -= 1 }
            await submit()
        }
    }

    /// Acts on `decision`: a blocker goes to `blocked`, a start is enqueued at once and awaited, so `isBusy` covers the
    /// whole submit, and a confirmation puts the question up and enqueues once the user agrees (`confirm`).
    /// - Parameter enqueue: queues the specs and reports its own errors; `overCapApproved` once the user agreed to go
    ///   over today's cap, which the engine refuses otherwise.
    public func handle(
        _ decision: SubmitDecision, blocked: @MainActor (String) -> Void,
        enqueue: @escaping @MainActor (_ specs: [JobSpec], _ overCapApproved: Bool) async -> Void
    ) async {
        switch decision {
        case .blocked(let reason):
            blocked(reason)
        case .start(let specs):
            await enqueue(specs, false)
        case .confirm(let specs, let confirmation):
            pending = Pending(confirmation: confirmation) { await enqueue(specs, true) }
        }
    }

    /// The user agreed to `pending`: its jobs are enqueued with the cap approved, as a submit of its own.
    /// - Returns: the submit's task; `nil` when it was dropped.
    @discardableResult
    public func confirm(_ pending: Pending) -> Task<Void, Never>? {
        if self.pending?.id == pending.id { self.pending = nil }
        return run(pending.approve)
    }
}
