import Foundation
import JutsuTestSupport
import Testing

@testable import JutsuAgent

@MainActor
@Suite struct OperationsTests {
    private let folder = "/tmp/Exports"

    private func file(_ item: UUID, _ status: AgentExportFile.Status = .done) -> AgentExportFile {
        AgentExportFile(item: item, status: status, file: status == .done ? "\(folder)/\(item).mov" : nil)
    }

    /// An export answers running at once; its files show as they finish, and in the order asked once it is done.
    @Test func anExportRunsOnItsOwnAndReportsEachFile() async {
        let operations = AgentOperations()
        let (first, second) = (UUID(), UUID())
        let gate = Gate<Void>()
        let started = operations.start(.export, folder: folder, total: 2) { report in
            report(self.file(second))
            try? await gate.wait()
            report(self.file(first, .failed))
            return .success([self.file(first, .failed), self.file(second)])
        }
        #expect(started.state == .running)
        #expect(started.job.state == "processing")
        #expect(started.job.kind == "export")
        await eventually { operations.operation(started.id)?.files.count == 1 }
        #expect(operations.operation(started.id)?.job.progress == 0.5)
        await gate.open(.success(()))
        await operations.finished(started.id)
        let done = operations.operation(started.id)
        #expect(done?.state == .done)
        #expect(done?.files.map(\.item) == [first, second])
        let job = done?.job
        #expect(job?.state == "done")
        #expect(job?.progress == 1)
        #expect(job?.results == ["\(folder)/\(second).mov"])
        #expect(job?.folder == folder)
        #expect(job?.finishedAt != nil)
    }

    @Test func anExportThatStopsSaysWhy() async {
        let operations = AgentOperations()
        let set = UUID()
        let started = operations.start(.deliveryExport, folder: folder, total: 3, set: set) { _ in
            .failure(AgentError(.failed, message: "The disk is full.", retryable: true))
        }
        await operations.finished(started.id)
        let job = operations.operation(started.id)?.job
        #expect(job?.state == "failed")
        #expect(job?.error == "The disk is full.")
        #expect(job?.kind == "delivery_export")
        #expect(job?.set == set)
    }

    /// Finished exports are forgotten after a day; running ones never.
    @Test func finishedExportsAreKeptForADay() async {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let operations = AgentOperations(now: { clock })
        let gate = Gate<Void>()
        let done = operations.start(.export, folder: folder, total: 0) { _ in .success([]) }
        let running = operations.start(.export, folder: folder, total: 1) { _ in
            try? await gate.wait()
            return .success([])
        }
        await operations.finished(done.id)
        clock += AgentOperations.keptFor + 1
        _ = operations.start(.export, folder: folder, total: 0) { _ in .success([]) }
        #expect(operations.operation(done.id) == nil)
        #expect(operations.operation(running.id) != nil)
        await gate.open(.success(()))
    }

    /// A handle the app no longer knows, as after a relaunch, answers `unknown` with a next step.
    @Test func aForgottenHandleIsUnknown() {
        let id = UUID()
        let job = AgentJob.unknown(id)
        #expect(job.id == id)
        #expect(job.state == "unknown")
        #expect(job.next?.isEmpty == false)
    }
}
