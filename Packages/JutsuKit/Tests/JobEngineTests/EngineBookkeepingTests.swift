import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

// The engine's bookkeeping on its own: submits in flight, the shared status call's waiters and pace, write turns
// and the network gate.

@Suite(.timeLimit(.minutes(1)))
struct SubmitTrackerTests {
    @Test func noSubmitStartsWhileStopping() {
        var submits = SubmitTracker()
        let id = UUID()
        submits.isStopping = true
        let whileStopping = submits.begin(id)
        #expect(!whileStopping)
        #expect(submits.inFlight.isEmpty)
        submits.isStopping = false
        let afterwards = submits.begin(id)
        #expect(afterwards)
        #expect(submits.inFlight == [id])
    }

    @Test func theLastAnswerReleasesTheStop() async {
        var submits = SubmitTracker()
        let (first, second) = (UUID(), UUID())
        _ = submits.begin(first)
        _ = submits.begin(second)
        await withCheckedContinuation { stop in
            submits.wait(stop)
            submits.finish(first)
            #expect(submits.waiterCount == 1)
            submits.finish(second)
            #expect(submits.waiterCount == 0)
        }
        #expect(submits.inFlight.isEmpty)
    }

    @Test func aStopWithNothingOutReturnsAtOnce() async {
        var submits = SubmitTracker()
        await withCheckedContinuation { submits.wait($0) }
        #expect(submits.waiterCount == 0)
    }

    @Test func runningOutOfTimeReleasesTheStopWithTheSubmitStillOut() async {
        var submits = SubmitTracker()
        let id = UUID()
        _ = submits.begin(id)
        let withoutWaiters = submits.releaseWaiters()
        #expect(!withoutWaiters)
        var released = false
        await withCheckedContinuation { stop in
            submits.wait(stop)
            released = submits.releaseWaiters()
        }
        #expect(released)
        #expect(submits.inFlight == [id])
    }
}

/// Owns a `StatusBatch` as the engine does: changed only on this actor, each waiter on a task of its own.
private actor StatusBatchOwner {
    var batch = StatusBatch()

    var waiting: Set<UUID> { Set(batch.waiting) }

    func wait(_ id: UUID) async throws -> BatchedStatus {
        try await withCheckedThrowingContinuation { batch.wait(id, $0) }
    }

    func answer(_ ids: [UUID], with answers: [UUID: BatchedStatus]) {
        batch.answer(ids, with: answers)
    }

    func drop(_ id: UUID) {
        batch.drop(id)
    }
}

extension BatchedStatus {
    fileprivate var status: RemoteStatus? {
        if case .status(let status) = self { status } else { nil }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct StatusBatchWaiterTests {
    @Test func eachWaiterGetsItsOwnAnswerOrGoesAlone() async throws {
        let owner = StatusBatchOwner()
        let (answered, missing) = (UUID(), UUID())
        let first = Task { try await owner.wait(answered) }
        let second = Task { try await owner.wait(missing) }
        await eventually { await owner.waiting == [answered, missing] }

        await owner.answer([answered, missing], with: [answered: .status(.inProgress)])

        #expect(try await first.value.status == .inProgress)
        #expect(try await second.value.status == nil)
        #expect(await owner.waiting.isEmpty)
    }

    @Test func aJobThatJoinsDuringTheCallWaitsForTheNextOne() async throws {
        let owner = StatusBatchOwner()
        let (early, late) = (UUID(), UUID())
        let first = Task { try await owner.wait(early) }
        await eventually { await owner.waiting == [early] }
        let asked = Array(await owner.waiting)
        let second = Task { try await owner.wait(late) }
        await eventually { await owner.waiting == [early, late] }

        await owner.answer(asked, with: [early: .status(.queued)])

        #expect(try await first.value.status == .queued)
        #expect(await owner.waiting == [late])
        await owner.drop(late)
        await #expect(throws: CancellationError.self) { try await second.value }
    }

    @Test func aDroppedWaiterIsCancelledAndNotAnsweredAgain() async throws {
        let owner = StatusBatchOwner()
        let id = UUID()
        let waiting = Task { try await owner.wait(id) }
        await eventually { await owner.waiting == [id] }

        await owner.drop(id)
        await owner.answer([id], with: [id: .status(.queued)])

        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await owner.waiting.isEmpty)
    }
}

@Suite struct StatusPaceTests {
    private let settings = EngineSettings(outputDirectory: URL(fileURLWithPath: "/tmp"), jitter: 0)

    @Test func waitsGrowUntilAStatusChanges() {
        let job = UUID()
        var pace = StatusPace(settings)
        #expect(pace.delay == 2)
        pace.update(answers: [job: .alone], pollAfter: nil)
        #expect(pace.delay == 3)
        pace.update(answers: [job: .status(.queued)], pollAfter: nil)
        #expect(pace.delay == 2)
        pace.update(answers: [job: .status(.queued)], pollAfter: nil)
        #expect(pace.delay == 3)
        pace.update(answers: [job: .status(.inProgress)], pollAfter: nil)
        #expect(pace.delay == 2)
    }

    @Test func aJobLeftOutOfAnAnswerIsForgotten() {
        let job = UUID()
        var pace = StatusPace(settings)
        pace.update(answers: [job: .status(.queued)], pollAfter: nil)
        pace.update(answers: [:], pollAfter: nil)
        #expect(pace.delay == 3)
        pace.update(answers: [job: .status(.queued)], pollAfter: nil)
        #expect(pace.delay == 2)
    }

    @Test func theWaitTheProviderAsksForIsKeptInRange() {
        var pace = StatusPace(settings)
        pace.update(answers: [:], pollAfter: 0)
        #expect(pace.delay == 1)
        pace.update(answers: [:], pollAfter: 7)
        #expect(pace.delay == 7)
        pace.update(answers: [:], pollAfter: 3600)
        #expect(pace.delay == 30)
        pace.update(answers: [:], pollAfter: .infinity)
        #expect(pace.delay == 3)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WriteTurnsTests {
    @Test func oneWriterPerJobAtATime() async {
        var turns = WriteTurns()
        let (job, other) = (UUID(), UUID())
        let first = [turns.take(job), turns.take(job), turns.take(other)]
        #expect(first == [true, false, true])
        await withCheckedContinuation { waiter in
            turns.wait(for: job, waiter)
            #expect(turns.hasWaiters(for: job))
            #expect(!turns.hasWaiters(for: other))
            turns.end(job)
        }
        #expect(!turns.hasWaiters(for: job))
        let afterEnd = [turns.take(job), turns.take(other)]
        #expect(afterEnd == [true, false])
    }
}

/// Owns a `NetworkGate` as the engine does, and records which waits returned.
private actor GateOwner {
    var gate = NetworkGate()
    var waiting = 0
    var passed: Set<UUID> = []

    func wait(_ token: UUID) async {
        waiting += 1
        await withCheckedContinuation { gate.wait(token, $0) }
        passed.insert(token)
    }

    func open(_ token: UUID? = nil) {
        if let token { gate.open(token) } else { gate.open() }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct NetworkGateTests {
    @Test func aCancelledWaiterLeavesAloneAndTheRestWaitForTheGate() async {
        let owner = GateOwner()
        let (cancelled, other) = (UUID(), UUID())
        let first = Task { await owner.wait(cancelled) }
        let second = Task { await owner.wait(other) }
        await eventually { await owner.waiting == 2 }

        await owner.open(cancelled)
        await first.value
        #expect(await owner.passed == [cancelled])

        await owner.open()
        await second.value
        #expect(await owner.passed == [cancelled, other])
    }
}
