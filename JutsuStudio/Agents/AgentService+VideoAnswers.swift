import Foundation
import JobEngine
import JutsuAgent
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// What create_video answers besides a new job: the wait for its price (wait_seconds), and the request sent again
// with a higher max_cost, which only the engine's check can let go on.
extension AgentService {
    /// The answer once every job's price is known or it is held (`AgentJobStatus.isPriced`), or when the wait ran
    /// out. A job gone from the live jobs has finished; waiting stops nothing.
    func waitForPrice(of created: AgentCreated, seconds: Int) async -> AgentCreated {
        let ids = created.jobs.map(\.id)
        let live = environment.liveJobs
        let timedOut = await agentWait(seconds: seconds) {
            ids.allSatisfy { id in live.job(id).map(AgentJobStatus.isPriced) ?? true }
        }
        var answer = created
        var jobs: [AgentJob] = []
        for job in created.jobs { jobs.append(await self.job(job.id).map(Self.agentJob) ?? job) }
        answer.jobs = jobs
        answer.timedOut = timedOut
        return answer
    }

    /// The request sent again with a higher `max_cost`: the engine lifts its job's over_max_cost hold when the price
    /// now fits every limit (`JobEngine.raiseAgentMaxCost`), and the request then stands for the new `max_cost`.
    /// Still held, the job comes back as it is with `next` saying why; `nil`, refused as `request_conflict`, for a job
    /// that isn't held over its `max_cost` or a `max_cost` that isn't higher.
    func raiseMaxCost(_ fields: CreateVideoCommand, of ids: [UUID]) async throws(AgentError) -> AgentCreated? {
        guard ids.count == 1, let id = ids.first else { return nil }
        let maxCost = AgentMoney(fields.maxCost.amount, Self.unit(of: fields.maxCost.unit))
        let raise: JobEngine.AgentMaxCostRaise
        do {
            raise = try await environment.engine.raiseAgentMaxCost(id, to: maxCost)
        } catch {
            throw AgentError(
                .failed, message: "Jutsu Studio can't check the job again: \(error.localizedDescription)",
                retryable: true, next: "Send the same create_video again in a moment.")
        }
        let next: String?
        switch raise {
        case .notLiftable: return nil
        case .lifted:
            next = nil
            do {
                try requests.update(fields.requestID, fingerprint: fields.fingerprint)
            } catch {
                logger.error("Can't record the raised max_cost: \(error.localizedDescription, privacy: .private)")
            }
        case .held(let hold): next = AgentJobRules.stillHeldNote(hold)
        case .overCap: next = AgentJobRules.stillHeldNote(nil)
        }
        guard let job = await job(id) else { return nil }
        var answer = Self.agentJob(job)
        answer.next = next
        return AgentCreated(requestID: fields.requestID, known: true, jobs: [answer])
    }
}
