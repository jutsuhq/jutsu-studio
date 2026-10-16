import Foundation
import JutsuCore

/// What the shared status call said about one job.
enum BatchedStatus: Sendable {
    case status(RemoteStatus)
    /// No answer for this job this time; the job asks `status` for itself at once.
    case alone
}

/// The jobs waiting for the next shared status call, and the ticker task that makes it (`JobEngine+StatusBatch`).
/// Each waiter is resumed once: with its answer, or with `CancellationError` when its task stops waiting.
/// Owned and changed only by the engine's actor.
struct StatusBatch {
    private var waiters: [UUID: CheckedContinuation<BatchedStatus, any Error>] = [:]
    /// Makes the shared calls while jobs poll through them; `nil` when none runs.
    var ticker: Task<Void, Never>?

    var isEmpty: Bool { waiters.isEmpty }

    /// The jobs waiting now, for the next call.
    var waiting: [UUID] { Array(waiters.keys) }

    /// Job `id` waits for the next call.
    mutating func wait(_ id: UUID, _ waiter: CheckedContinuation<BatchedStatus, any Error>) {
        waiters[id] = waiter
    }

    /// Job `id` stops waiting, as its task was cancelled.
    mutating func drop(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Hands each of `ids` still waiting its entry of `answers`, or `.alone` when the call had none for it.
    mutating func answer(_ ids: [UUID], with answers: [UUID: BatchedStatus]) {
        for id in ids { waiters.removeValue(forKey: id)?.resume(returning: answers[id] ?? .alone) }
    }

    /// `items` in order, in groups of at most `size` (at least 1).
    static func groups<Item>(_ items: [Item], of size: Int) -> [[Item]] {
        let size = max(size, 1)
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}

/// How long the ticker waits before the next shared status call: as long as the provider asked (`BatchStatus.pollAfter`,
/// kept in `serverPollDelay`) or, when it didn't say, as a job polled alone would: Higgsfield's backoff, reset
/// whenever a job's status changes.
struct StatusPace {
    private var backoff: Backoff
    private let serverDelay: ClosedRange<TimeInterval>
    /// Each answered job's last status, to see a change; a job left out of an answer is forgotten.
    private var last: [UUID: RemoteStatus] = [:]
    /// The wait before the next call, in seconds.
    private(set) var delay: TimeInterval

    init(_ settings: EngineSettings) {
        backoff = .polling(settings)
        serverDelay = settings.serverPollDelay
        delay = backoff.next()
    }

    /// Takes in one round of calls: what they answered and the shortest wait they asked for.
    mutating func update(answers: [UUID: BatchedStatus], pollAfter: TimeInterval?) {
        var changed = false
        for (id, answer) in answers {
            guard case .status(let status) = answer else { continue }
            changed = changed || last[id] != status
            last[id] = status
        }
        last = last.filter { answers[$0.key] != nil }
        if changed { backoff.reset() }
        if let pollAfter, pollAfter.isFinite {
            delay = min(max(pollAfter, serverDelay.lowerBound), serverDelay.upperBound)
        } else {
            delay = backoff.next()
        }
    }
}
