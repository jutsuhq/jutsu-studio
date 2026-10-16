import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

/// A double click on Generate sends two enqueues before the first is saved.
@Suite(.timeLimit(.minutes(1)))
struct EnqueueTests {
    @Test(arguments: [false, true])
    func unreadableSpendingSendsNothingEvenWithAnEarlierCapApproval(approved: Bool) async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine { _ in throw BudgetError.spendingUnavailable }
        await #expect(throws: BudgetError.self) {
            try await engine.enqueue(makeSpec(), overCapApproved: approved)
        }
        #expect(try await harness.repository.activeJobs().isEmpty)
        #expect(await harness.provider.submitKeys.isEmpty)
    }

    @Test func theSameRequestSentWhileTheFirstIsQueueingMakesOneJob() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()
        let spec = makeSpec()
        let gates = await harness.repository.holdSave { $0.state == .preparing }

        async let first = engine.enqueue(spec)
        try await gates.reached.wait()
        async let second = engine.enqueue(spec, batchID: UUID())
        // The second has to reach the engine while the first is held; nothing observable marks that.
        await quiesce()
        await gates.release.open(.success(()))
        let (a, b) = try await (first, second)

        #expect(a.id == b.id)
        #expect(harness.log.count("estimate") == 1)
        #expect(await harness.repository.wait(for: a.id, .done) != nil)
        #expect(await harness.provider.submitKeys == [a.idempotencyKey])

        let again = try await engine.enqueue(spec)
        #expect(again.id != a.id)
    }

    @Test func twoSubmitsThatReadTheSpendAtOnceCantBothPassTheCap() async throws {
        let harness = Harness()
        let repository = harness.repository
        let log = harness.log
        let firstRead = Gate<Void>()
        let release = Gate<Void>()
        let engine = try await harness.makeEngine { job in
            let committed = Budget.committed(
                ((try? await repository.activeJobs()) ?? []).filter { $0.id != job.id }, on: .now, in: .usd)
            log.append("spendStatus")
            if log.count("spendStatus") == 1 {
                await firstRead.open(.success(()))
                _ = try? await release.wait()
            }
            return SpendStatus(committedToday: committed, cap: .usd(2))
        }

        async let first = engine.enqueue(makeSpec(references: 1))
        try await firstRead.wait()
        let second = Task { try await engine.enqueue(makeSpec(references: 2)) }
        // Without the engine taking turns, the second would read the same spend now and pass too.
        await quiesce()
        await release.open(.success(()))

        let queued = try await first
        await #expect(throws: JobEngineError.overCap) { try await second.value }
        #expect(try await repository.activeJobs().map(\.id) == [queued.id])
    }

    @Test func overTheCapOnlyAnApprovedEnqueueQueues() async throws {
        let harness = Harness(spendStatus: SpendStatus(committedToday: 2, cap: .usd(3)))
        let engine = try await harness.makeEngine()

        await #expect(throws: JobEngineError.overCap) { try await engine.enqueue(makeSpec()) }
        #expect(try await harness.repository.activeJobs().isEmpty)

        let job = try await engine.enqueue(makeSpec(), overCapApproved: true)
        #expect(await harness.repository.wait(for: job.id, .done) != nil)
    }

    /// The account's Seedance makes 16:9 from a 9:16 start frame unless it is told the frame (live, 2026-10-15), so a
    /// clip from frames is queued with the start frame's shape; one whose frame can't be read keeps none.
    @Test(arguments: [
        (PixelSize(width: 480, height: 854), AspectRatio.portrait as AspectRatio?),
        (PixelSize(width: 1000, height: 1000), .square), (PixelSize(width: 2100, height: 900), .cinema),
        (nil, nil),
    ])
    func aClipFromFramesTakesTheStartFramesShape(size: PixelSize?, expected: AspectRatio?) async throws {
        var harness = Harness()
        harness.imageSize = size
        let engine = try await harness.makeEngine()
        let frames = [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/first.png"))]
        let spec = JobSpec(
            mode: .motionTransfer, model: .seedance25, source: nil, references: frames, resolution: .p480, length: 4,
            referencesAreFrames: true)

        #expect(try await engine.enqueue(spec).spec.aspectRatio == expected)

        // References aren't frames: the frame asked for stays.
        var references = spec
        references.referencesAreFrames = false
        references.aspectRatio = .landscape
        #expect(try await engine.enqueue(references).spec.aspectRatio == .landscape)
    }
}
