import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// What runs an agent's paid request once for its request ID.
@MainActor
@Suite struct AgentRequestGateTests {
    struct Refused: Error, Equatable {
        let reason: String
    }

    let log = AgentRequestLog(folder: nil)
    let refusals = AgentRequestGate<String, Refused>.Refusals(
        conflict: Refused(reason: "conflict"), unreadable: Refused(reason: "unreadable"),
        neverQueued: Refused(reason: "never queued"))

    /// Runs `queue` through `gate`, counting the discards; `known` answers for the recorded IDs.
    private func run(
        _ gate: AgentRequestGate<String, Refused>, _ requestID: String = "r1", fingerprint: String = "f1",
        discards: Box<Int>, known: @escaping ([UUID]) -> String? = { _ in nil },
        queue: @escaping @MainActor () async throws(Refused) -> String
    ) async throws(Refused) -> String {
        try await gate.run(
            requestID, fingerprint: fingerprint, refusals: refusals, discard: { discards.update { $0 += 1 } },
            known: { known($0) }, queue: queue)
    }

    @Test func aRecordedRequestAnswersWithWhatItMadeAndRunsNothing() async throws {
        let gate = AgentRequestGate<String, Refused>(log: log)
        let job = UUID()
        try gate.record("r1", fingerprint: "f1", ids: [job], at: .now)
        let discards = Box(0)
        let answer = try await run(gate, discards: discards, known: { $0 == [job] ? "known" : nil }) {
            Issue.record("A known request ran again")
            return "ran"
        }
        #expect(answer == "known")
        #expect(discards.value == 1)
        #expect(try gate.state(of: "r1", fingerprint: "f1") == .known([job]))
    }

    /// Recorded, but what it made was never saved: it is forgotten, so the same request runs when sent again.
    @Test func aRecordedRequestThatMadeNothingIsForgotten() async throws {
        let gate = AgentRequestGate<String, Refused>(log: log)
        try gate.record("r1", fingerprint: "f1", ids: [UUID()], at: .now)
        let discards = Box(0)
        await #expect(throws: Refused(reason: "never queued")) {
            try await run(gate, discards: discards) { "ran" }
        }
        #expect(try gate.state(of: "r1", fingerprint: "f1") == .new)
        #expect(try await run(gate, discards: discards) { "ran" } == "ran")
    }

    @Test func theIDWithOtherParametersIsAConflict() async throws {
        let gate = AgentRequestGate<String, Refused>(log: log)
        try gate.record("r1", fingerprint: "f1", ids: [UUID()], at: .now)
        let discards = Box(0)
        await #expect(throws: Refused(reason: "conflict")) {
            try await run(gate, fingerprint: "f2", discards: discards) { "ran" }
        }
        #expect(discards.value == 1)
    }

    /// The same request sent while it runs waits for that run, and its own copies of the files are discarded; the ID
    /// with other parameters is refused meanwhile.
    /// The same parameters with another max_cost go to `otherMaxCost`, which may answer or refuse; a request without
    /// parameters, or recorded without them, stays a conflict.
    @Test func theSameParametersWithAnotherMaxCostAskWhetherTheHoldLifts() async throws {
        let gate = AgentRequestGate<String, Refused>(log: log)
        let job = UUID()
        try gate.record("r1", fingerprint: "f1", parameters: "p1", ids: [job], at: .now)
        #expect(try gate.state(of: "r1", fingerprint: "f2", parameters: "p1") == .otherMaxCost([job]))
        #expect(try gate.state(of: "r1", fingerprint: "f2", parameters: "p2") == .conflict)
        #expect(try gate.state(of: "r1", fingerprint: "f2") == .conflict)
        let discards = Box(0)
        let raise = { (fingerprint: String, answer: String?) async throws(Refused) -> String in
            try await gate.run(
                "r1", fingerprint: fingerprint, parameters: "p1", refusals: refusals,
                discard: { discards.update { $0 += 1 } }, known: { _ in "known" },
                otherMaxCost: { $0 == [job] ? answer : nil }
            ) {
                Issue.record("A request sent again ran again")
                return "ran"
            }
        }
        #expect(try await raise("f2", "lifted") == "lifted")
        await #expect(throws: Refused(reason: "conflict")) { try await raise("f3", nil) }
        #expect(discards.value == 2)

        try gate.update("r1", fingerprint: "f2")
        #expect(try gate.state(of: "r1", fingerprint: "f2", parameters: "p1") == .known([job]))
        #expect(try gate.state(of: "r1", fingerprint: "f1", parameters: "p1") == .otherMaxCost([job]))

        try gate.record("r2", fingerprint: "f1", ids: [job], at: .now)
        #expect(try gate.state(of: "r2", fingerprint: "f2", parameters: "p1") == .conflict)
    }

    /// Records written before parameters existed still read.
    @Test func aRecordWithoutParametersDecodes() throws {
        let json = #"{"requestID":"r1","fingerprint":"f1","jobIDs":[],"createdAt":0}"#
        let record = try JSONDecoder().decode(AgentRequestLog.Record.self, from: Data(json.utf8))
        #expect(record.parameters == nil && record.fingerprint == "f1")
    }

    @Test func theSameRequestSentWhileItRunsJoinsIt() async throws {
        let gate = AgentRequestGate<String, Refused>(log: log)
        let release = Gate<Void>()
        let runs = Box(0)
        let discards = Box(0)
        let first = Task { @MainActor in
            try await run(gate, discards: discards) { () throws(Refused) -> String in
                runs.update { $0 += 1 }
                try? gate.record("r1", fingerprint: "f1", ids: [UUID()], at: .now)
                _ = try? await release.wait()
                return "made"
            }
        }
        await eventually { runs.value == 1 }
        #expect(try gate.state(of: "r1", fingerprint: "f1") == .running)
        await #expect(throws: Refused(reason: "conflict")) {
            try await run(gate, fingerprint: "f2", discards: discards) { "other" }
        }
        let second = Task { @MainActor in
            try await run(gate, discards: discards) { "ran twice" }
        }
        await release.open(.success(()))
        #expect(try await first.value == "made")
        #expect(try await second.value == "made")
        #expect(runs.value == 1)
        // The conflict's files and the second request's; the first run's files are its job's.
        #expect(discards.value == 2)
    }

    /// A run that fails is forgotten and its files discarded, so the agent can fix it and send it again.
    @Test func aFailedRunIsForgotten() async throws {
        let gate = AgentRequestGate<String, Refused>(log: log)
        let discards = Box(0)
        await #expect(throws: Refused(reason: "bad prompt")) {
            try await run(gate, discards: discards) { () throws(Refused) -> String in
                try? gate.record("r1", fingerprint: "f1", ids: [UUID()], at: .now)
                throw Refused(reason: "bad prompt")
            }
        }
        #expect(discards.value == 1)
        #expect(try gate.state(of: "r1", fingerprint: "f1") == .new)
        #expect(try await run(gate, discards: discards) { "ran" } == "ran")
        #expect(discards.value == 1)
    }
}
