import Foundation
import JutsuCore

/// A job of a request sent again with a higher `max_cost`, and why it still waits when it does.
public struct AgentRaisedJob: Sendable, Hashable {
    public var job: Job
    /// Why the job still waits (`AgentJobRules.stillHeldNote`); `nil` once it goes on.
    public var note: String?

    public init(job: Job, note: String? = nil) {
        self.job = job
        self.note = note
    }
}

/// `create_video` sent again with its parameters and a higher `max_cost` (`AgentRequestGate.State.otherMaxCost`):
/// what the engine's check of its job (`JobEngine.raiseAgentMaxCost`) answers the agent. Only the engine decides
/// whether the job goes on; this only words the answer and keeps the request's record in step with it.
@MainActor
public enum AgentMaxCostRaising {
    private static let events = PresentationLog(category: "Agents")

    /// - Parameters:
    ///   - ids: what the request recorded; only a request of one job can be raised.
    ///   - raise: the engine's check of the job against `maxCost`; `nil` when the job isn't there.
    ///   - job: the job as it is now; `nil` when it isn't there, and throws when that can't be known (a job not read
    ///     could still exist, and forgetting its request would let the agent pay twice).
    ///   - recordRaise: from now on the request is the one with the new `max_cost` (`AgentRequestGate.update`). A
    ///     failure is logged: the same request sent again finds the job already raised and records it then.
    public static func answer<E: Error>(
        _ ids: [UUID], maxCost: AgentMoney, raise: (UUID, AgentMoney) async throws(E) -> AgentMaxCostRaise?,
        job: (UUID) async throws(E) -> Job?, recordRaise: () throws -> Void
    ) async throws(E) -> AgentRaiseOutcome<AgentRaisedJob> {
        guard ids.count == 1, let id = ids.first else { return .notLiftable }
        guard let result = try await raise(id, maxCost) else { return .gone }
        let note: String?
        switch result {
        case .lifted:
            note = nil
            record(recordRaise)
        case .held(let hold): note = AgentJobRules.stillHeldNote(hold)
        case .overCap: note = AgentJobRules.stillHeldNote(nil)
        case .notLiftable:
            // Already raised to this max_cost: a raise whose record wasn't updated, or one that finished while this
            // request was on its way. It is the same request, so it answers as known instead of a conflict, which
            // an agent may answer with a new request_id and pay twice.
            guard let current = try await job(id) else { return .gone }
            guard current.agent?.maxCost == maxCost else { return .notLiftable }
            record(recordRaise)
            return .answer(AgentRaisedJob(job: current))
        }
        guard let current = try await job(id) else { return .gone }
        return .answer(AgentRaisedJob(job: current, note: note))
    }

    private static func record(_ recordRaise: () throws -> Void) {
        do {
            try recordRaise()
        } catch {
            events.error("The raised max_cost can't be recorded", detail: String(describing: error))
        }
    }
}
