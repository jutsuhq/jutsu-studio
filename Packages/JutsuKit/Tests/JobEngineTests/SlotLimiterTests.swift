import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import JobEngine

@Suite(.timeLimit(.minutes(1)))
struct SlotLimiterTests {
    actor Order {
        var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }

    @Test func waitersAreServedInArrivalOrder() async throws {
        let limiter = SlotLimiter(limit: 1)
        let order = Order()
        try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast))

        let first = Task {
            try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast))
            await order.append(1)
        }
        await eventually { await limiter.waiterCount == 1 }
        let second = Task {
            try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast))
            await order.append(2)
        }
        await eventually { await limiter.waiterCount == 2 }

        await limiter.release()
        try await first.value
        #expect(await order.values == [1])
        await limiter.release()
        try await second.value
        #expect(await order.values == [1, 2])
    }

    @Test func raisingTheLimitAdmitsWaiters() async throws {
        let limiter = SlotLimiter(limit: 1)
        try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast))
        let waiter = Task { try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast)) }
        await eventually { await limiter.waiterCount == 1 }

        await limiter.setLimit(2)
        try await waiter.value
        #expect(await limiter.inUse == 2)
    }

    @Test func canceledWaiterLeavesTheQueue() async throws {
        let limiter = SlotLimiter(limit: 1)
        try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast))
        let waiter = Task { try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast)) }
        await eventually { await limiter.waiterCount == 1 }

        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await limiter.waiterCount == 0)
        await limiter.release()
        #expect(await limiter.inUse == 0)
    }

    @Test func occupyCountsBeyondTheLimit() async {
        let limiter = SlotLimiter(limit: 1)
        await limiter.occupy()
        await limiter.occupy()
        #expect(await limiter.inUse == 2)
    }

    /// Holds one slot and queues one waiter per order.
    private func queue(
        _ orders: [SlotOrder], on limiter: SlotLimiter, served: Order
    ) async throws -> ([UUID], [Task<Void, Error>]) {
        try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast))
        var ids: [UUID] = []
        var tasks: [Task<Void, Error>] = []
        for (index, order) in orders.enumerated() {
            let id = UUID()
            ids.append(id)
            let task = Task {
                try await limiter.acquire(id, order: order)
                await served.append(index)
            }
            tasks.append(task)
            await eventually { await limiter.waiterCount == index + 1 }
        }
        return (ids, tasks)
    }

    private func finish(_ tasks: [Task<Void, Error>]) async {
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func waitersAreServedOldestFirstWhateverTheArrival() async throws {
        let limiter = SlotLimiter(limit: 1)
        let served = Order()
        let (ids, tasks) = try await queue(
            [SlotOrder(queuedAt: at(30)), SlotOrder(queuedAt: at(10)), SlotOrder(queuedAt: at(20))], on: limiter,
            served: served)

        #expect(await limiter.waitingIDs == [ids[1], ids[2], ids[0]])
        await finish(tasks)
    }

    @Test func promotedWaiterTakesTheNextSlot() async throws {
        let limiter = SlotLimiter(limit: 2)
        try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast))
        let served = Order()
        let (ids, tasks) = try await queue(
            (1...5).map { SlotOrder(queuedAt: at(Double($0))) }, on: limiter, served: served)

        await limiter.promote(ids[4], at: at(100))
        #expect(await limiter.waitingIDs == [ids[4], ids[0], ids[1], ids[2], ids[3]])
        await limiter.release()
        await eventually { await served.values == [4] }
        await limiter.release()
        await eventually { await served.values == [4, 0] }
        await finish(tasks)
    }

    @Test func latestPromotionGoesFirstAndPromotingAnIdleIDDoesNothing() async throws {
        let limiter = SlotLimiter(limit: 1)
        let served = Order()
        let (ids, tasks) = try await queue(
            (1...3).map { SlotOrder(queuedAt: at(Double($0))) }, on: limiter, served: served)

        await limiter.promote(ids[1], at: at(100))
        await limiter.promote(ids[2], at: at(200))
        await limiter.promote(UUID(), at: at(300))
        #expect(await limiter.waitingIDs == [ids[2], ids[1], ids[0]])

        let late = UUID()
        let lateTask = Task { try await limiter.acquire(late, order: SlotOrder(queuedAt: at(0), promotedAt: at(150))) }
        await eventually { await limiter.waiterCount == 4 }
        #expect(await limiter.waitingIDs == [ids[2], late, ids[1], ids[0]])
        await finish(tasks + [lateTask])
    }

    @Test func cancelingAPromotedWaiterServesTheNextInOrder() async throws {
        let limiter = SlotLimiter(limit: 1)
        try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .distantPast))
        let promoted = UUID()
        let waiter = Task { try await limiter.acquire(promoted, order: SlotOrder(queuedAt: at(2))) }
        await eventually { await limiter.waiterCount == 1 }
        let served = Order()
        let other = UUID()
        let otherTask = Task {
            try await limiter.acquire(other, order: SlotOrder(queuedAt: at(1)))
            await served.append(1)
        }
        await eventually { await limiter.waiterCount == 2 }
        await limiter.promote(promoted, at: at(100))

        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await limiter.waitingIDs == [other])
        await limiter.release()
        try await otherTask.value
        #expect(await served.values == [1])
        #expect(await limiter.inUse == 1)
    }

    @Test func raisingTheLimitAdmitsWaitersInOrder() async throws {
        let limiter = SlotLimiter(limit: 1)
        let served = Order()
        let (ids, tasks) = try await queue(
            (1...3).map { SlotOrder(queuedAt: at(Double($0))) }, on: limiter, served: served)
        await limiter.promote(ids[2], at: at(100))

        await limiter.setLimit(3)
        await eventually { await served.values.count == 2 }
        #expect(Set(await served.values) == [2, 0])
        #expect(await limiter.waitingIDs == [ids[1]])
        #expect(await limiter.inUse == 3)
        await finish(tasks)
    }

    /// Higgsfield's polling guide: 2 s, growing by 1.5× up to 10 s.
    @Test func pollingFollowsTheDocumentedScheduleAndResets() {
        let settings = EngineSettings(outputDirectory: URL(fileURLWithPath: "/tmp"), jitter: 0)
        var backoff = Backoff.polling(settings)
        #expect((0..<6).map { _ in backoff.next() } == [2, 3, 4.5, 6.75, 10, 10])
        backoff.reset()
        #expect(backoff.next() == 2)
    }

    @Test func retriesDoubleToTheCap() {
        let settings = EngineSettings(outputDirectory: URL(fileURLWithPath: "/tmp"), jitter: 0)
        var backoff = Backoff.retrying(settings)
        #expect((0..<6).map { _ in backoff.next() } == [5, 10, 20, 40, 60, 60])
    }

    @Test func jitterStaysWithinBounds() {
        let settings = EngineSettings(outputDirectory: URL(fileURLWithPath: "/tmp"), jitter: 0.2)
        var backoff = Backoff.polling(settings)
        let first = backoff.next()
        #expect(first >= 1.6 && first <= 2.4)
    }
}
