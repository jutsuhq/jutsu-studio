import Foundation
import JutsuAgent
import JutsuCore
import Presentation

// jobs and job_action: following the agents' video jobs, image requests and exports, and acting on them.
extension AgentService {
    // MARK: jobs

    func jobs(_ fields: JobsCommand) async throws(AgentError) -> AgentJobs {
        let started = ContinuousClock.now
        var ids = fields.ids
        var next: String?
        let operations = operations
        if ids.isEmpty {
            let videos = environment.liveJobs.all.filter { $0.agent != nil }.map { ($0.createdAt, $0.id) }
            let images = ((try? environment.agentImages.records()) ?? []).map { ($0.createdAt, $0.id) }
            let exports = operations.all.map { ($0.createdAt, $0.id) }
            (ids, next) = AgentJobPage.page(videos + images + exports, limit: fields.limit ?? 10, after: fields.cursor)
        }
        let live = environment.liveJobs
        let images = environment.agentImages
        // Cut to what is left of the answer deadline, as create_video's wait is, so the answer keeps its margin
        // before the deadline whatever reading the page took.
        let seconds = AgentProtocol.waitSeconds(fields.waitSeconds, after: ContinuousClock.now - started)
        let timedOut =
            fields.waitSeconds > 0
            ? await agentWait(seconds: seconds) {
                ids.allSatisfy { id in
                    if let job = live.job(id) { return AgentJob.isSettled(job.state) }
                    if let operation = operations.operation(id) { return operation.state != .running }
                    guard let record = images.record(id) else { return true }
                    return (record.isOver && !images.files(of: id).isEmpty) || record.state == .held
                        || record.state == .failed || record.state == .canceled
                }
            } : false
        var jobs: [AgentJob] = []
        for id in ids {
            if let job = await job(id) {
                jobs.append(AgentJob(job))
            } else if let image = await imageJob(id) {
                jobs.append(image)
            } else if let operation = operations.operation(id) {
                jobs.append(operation.job)
            } else {
                jobs.append(.unknown(id))
            }
        }
        return AgentJobs(jobs: jobs, timedOut: timedOut, nextCursor: next)
    }

    // MARK: job_action

    func act(_ fields: JobActionCommand) async throws(AgentError) -> AgentActed {
        let engine = environment.engine
        guard let id = fields.job else {
            switch fields.action {
            // Agents' jobs only: an agent never pauses the person's jobs or lifts their own Pause all.
            case .pauseQueue: await engine.pauseAll(agentsOnly: true)
            case .resumeQueue: await engine.resumeAll(agentsOnly: true)
            case .cancel, .retry, .runNext: throw .badRequest("\(fields.action.rawValue) needs job")
            }
            return AgentActed(action: fields.action)
        }
        guard let job = await job(id) else {
            if environment.agentImages.record(id) != nil { return try await actOnImage(fields.action, id) }
            throw AgentError(.notFound, message: "There's no job \(id.uuidString).", retryable: false)
        }
        let refusal: String? =
            switch fields.action {
            case .cancel: AgentJobRules.cancelRefusal(job)
            case .retry:
                AgentJobRules.retryRefusal(job) {
                    FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
                }
            case .runNext: AgentJobRules.runNextRefusal(job)
            case .pauseQueue, .resumeQueue: nil
            }
        if let refusal {
            throw AgentError(
                .needsPerson, message: refusal, retryable: false, next: "Ask the person to decide in the Queue.")
        }
        do {
            switch fields.action {
            case .cancel: try await engine.cancel(id)
            case .retry: try await engine.retry(id)
            case .runNext: try await engine.runNext(id)
            case .pauseQueue, .resumeQueue: break
            }
        } catch {
            throw AgentError(
                .notApplicable, message: error.localizedDescription,
                retryable: Self.isSubmitInProgress(error),
                next: "Call jobs to see the job's state now.")
        }
        return AgentActed(action: fields.action, job: await self.job(id).map(AgentJob.init))
    }
}
