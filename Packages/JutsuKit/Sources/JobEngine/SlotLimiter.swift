import Foundation

/// Async semaphore for the account's generation slots. Waiters are served in `SlotOrder`, and the limit
/// can change at any time, e.g. when the API reports its own.
public actor SlotLimiter {
    public private(set) var limit: Int
    public private(set) var inUse = 0
    /// Sorted by `order`, then by arrival.
    private var waiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        var order: SlotOrder
        let continuation: CheckedContinuation<Void, any Error>
    }

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    var waiterCount: Int { waiters.count }

    /// The waiting ids, next to be served first.
    var waitingIDs: [UUID] { waiters.map(\.id) }

    /// Waits for a free slot for `id`. Throws `CancellationError` if the task is canceled while waiting.
    public func acquire(_ id: UUID, order: SlotOrder) async throws {
        try Task.checkCancellation()
        if waiters.isEmpty, inUse < limit {
            inUse += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                insert(Waiter(id: id, order: order, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Moves a waiting `id` ahead of the others as promoted at `date`. Does nothing when it isn't waiting.
    public func promote(_ id: UUID, at date: Date) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        var waiter = waiters.remove(at: index)
        waiter.order.promotedAt = date
        insert(waiter)
    }

    /// Takes a slot even when none is free: a job the API already accepted holds one regardless.
    public func occupy() {
        inUse += 1
    }

    public func release() {
        inUse = max(0, inUse - 1)
        grant()
    }

    public func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        grant()
    }

    private func insert(_ waiter: Waiter) {
        let index = waiters.firstIndex { waiter.order < $0.order } ?? waiters.endIndex
        waiters.insert(waiter, at: index)
    }

    private func grant() {
        while inUse < limit, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            inUse += 1
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Where a job waits for a slot: promoted jobs first, the latest promotion ahead, then the rest oldest first.
/// Built from saved dates only, so jobs resumed after a restart line up as before.
public struct SlotOrder: Comparable, Sendable {
    public var queuedAt: Date
    public var promotedAt: Date?

    public init(queuedAt: Date, promotedAt: Date? = nil) {
        self.queuedAt = queuedAt
        self.promotedAt = promotedAt
    }

    public static func < (lhs: SlotOrder, rhs: SlotOrder) -> Bool {
        switch (lhs.promotedAt, rhs.promotedAt) {
        case (let left?, let right?): left > right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs.queuedAt < rhs.queuedAt
        }
    }
}
