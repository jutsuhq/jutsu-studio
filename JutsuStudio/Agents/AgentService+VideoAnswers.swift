import Foundation
import JobEngine
import JutsuAgent
import JutsuCore
import Presentation

// What create_video answers besides a new job: the wait for its price (wait_seconds), and the request sent again
// with a higher max_cost, which only the engine's check can let go on.
extension AgentService {
    /// The answer once every job's price is known or it is held (`AgentJob.isPriced`), or when the wait ran
    /// out. A job gone from the live jobs has finished; waiting stops nothing.
    func waitForPrice(of created: AgentCreated, seconds: Int) async -> AgentCreated {
        let ids = created.jobs.map(\.id)
        let live = environment.liveJobs
        let timedOut = await agentWait(seconds: seconds) {
            ids.allSatisfy { id in live.job(id).map(AgentJob.isPriced) ?? true }
        }
        var answer = created
        var jobs: [AgentJob] = []
        for job in created.jobs {
            jobs.append(await self.job(job.id).map { AgentJob($0).keepingNext(of: job) } ?? job)
        }
        answer.jobs = jobs
        answer.timedOut = timedOut
        return answer
    }

    /// The request sent again with a higher `max_cost`: the engine lifts its job's over_max_cost hold when the price
    /// now fits every limit (`JobEngine.raiseAgentMaxCost`), and the request then stands for the new `max_cost`
    /// (`AgentMaxCostRaising`). Still held, the job comes back as it is with `next` saying why; not liftable, refused
    /// as `request_conflict`, for a job that isn't held over its `max_cost` or a `max_cost` that isn't higher; a job
    /// gone from the store is answered as never queued, like a known request's.
    func raiseMaxCost(
        _ fields: CreateVideoCommand, of ids: [UUID]
    ) async throws(AgentError) -> AgentRaiseOutcome<AgentCreated> {
        let engine = environment.engine
        let requests = requests
        let outcome = try await AgentMaxCostRaising.answer(
            ids, maxCost: AgentMoney(fields.maxCost),
            raise: { id, maxCost throws(AgentError) in
                do {
                    return try await engine.raiseAgentMaxCost(id, to: maxCost)
                } catch JobEngineError.unknownJob {
                    return nil
                } catch {
                    throw AgentError(
                        .failed, message: "Jutsu Studio can't check the job again: \(error.localizedDescription)",
                        retryable: true, next: "Send the same create_video again in a moment.")
                }
            },
            job: { [weak self] id throws(AgentError) in try await self?.knownJobs([id]).first },
            recordRaise: { try requests.update(fields.requestID, fingerprint: fields.fingerprint) })
        return outcome.map { raised in
            var answer = AgentJob(raised.job)
            answer.next = raised.note ?? answer.next
            return AgentCreated(requestID: fields.requestID, known: true, jobs: [answer])
        }
    }
}
