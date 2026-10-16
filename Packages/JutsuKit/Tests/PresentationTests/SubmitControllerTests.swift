import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

@MainActor
@Suite struct SubmitControllerTests {
    private let specs = [
        JobSpec(mode: .restyle, source: nil, prompt: "rain", resolution: .p720),
        JobSpec(mode: .restyle, source: nil, prompt: "snow", resolution: .p720),
    ]
    private let confirmation = CapConfirmation(
        title: "Over today's cap", message: "This takes today past your cap.", confirmTitle: "Start anyway")

    /// One call of `enqueue`.
    private struct Call: Sendable, Equatable {
        var specs: [JobSpec]
        var overCapApproved: Bool
    }

    @Test func startEnqueuesAtOnceAndStaysBusyUntilQueued() async throws {
        let controller = SubmitController()
        let gate = Gate<Bool>()
        let enqueued = Box<[Call]>([])
        let specs = specs
        let task = controller.run {
            await controller.handle(.start(specs), blocked: { _ in Issue.record("Not blocked") }) { specs, approved in
                enqueued.update { $0.append(Call(specs: specs, overCapApproved: approved)) }
                try? await gate.wait()
            }
        }
        #expect(controller.isBusy)
        await eventually { await gate.isWaiting }
        #expect(controller.isBusy)
        await gate.open(.success(true))
        await task?.value
        #expect(!controller.isBusy)
        #expect(enqueued.value == [Call(specs: specs, overCapApproved: false)])
        #expect(controller.pending == nil)
    }

    @Test func aBlockerIsReportedAndNothingIsQueued() async {
        let controller = SubmitController()
        let reasons = Box<[String]>([])
        await controller.run {
            await controller.handle(
                .blocked("Add a source video"), blocked: { reason in reasons.update { $0.append(reason) } }
            ) { _, _ in
                Issue.record("Nothing is queued")
            }
        }?.value
        #expect(reasons.value == ["Add a source video"])
        #expect(!controller.isBusy)
    }

    @Test func overTheCapAsksFirstAndQueuesTheSameJobsApproved() async throws {
        let controller = SubmitController()
        let enqueued = Box<[Call]>([])
        let specs = specs
        let confirmation = confirmation
        await controller.run {
            await controller.handle(.confirm(specs, confirmation), blocked: { _ in }) { specs, approved in
                enqueued.update { $0.append(Call(specs: specs, overCapApproved: approved)) }
            }
        }?.value
        #expect(enqueued.value.isEmpty)
        // The question doesn't hold the flag, so it is free again once the dialog is up.
        #expect(!controller.isBusy)
        let pending = try #require(controller.pending)
        #expect(pending.confirmation == confirmation)

        await controller.confirm(pending)?.value
        #expect(controller.pending == nil)
        #expect(enqueued.value == [Call(specs: specs, overCapApproved: true)])
    }

    @Test func aSecondClickWhileOneRunsIsDropped() async throws {
        let controller = SubmitController()
        let gate = Gate<Bool>()
        let runs = Box(0)
        let first = controller.run {
            runs.update { $0 += 1 }
            try? await gate.wait()
        }
        #expect(controller.run { runs.update { $0 += 1 } } == nil)
        await gate.open(.success(true))
        await first?.value
        #expect(runs.value == 1)
        await controller.run { runs.update { $0 += 1 } }?.value
        #expect(runs.value == 2)
    }
}
