import Foundation
import JutsuCore

extension JobEngine {
    /// What makes two enqueues the same request. The batch isn't part of it: each submit of a batch makes a new one.
    struct EnqueueRequest: Hashable {
        let spec: JobSpec
        let parentID: UUID?
        /// Two agent requests of the same spec are two jobs.
        let agentRequest: String?
    }

    /// Queues a job. The caller asks the user first when `Budget.allows` says so; the engine checks the cap again
    /// (`spendStatus`) and throws `overCap` unless `overCapApproved`, so two submits that both read today's spend
    /// before either was queued can't both pass it. Enqueues run one at a time, each after the one before is
    /// saved. An enqueue of the same spec and parent while an equal one is still running (a double click) returns
    /// that job instead of queueing and paying for a second.
    /// - Parameters:
    ///   - parentID: the library item the job is made from, if any.
    ///   - batchID: the batch the job belongs to; batch jobs take slots like any other job.
    ///   - overCapApproved: the user agreed to go over today's cap with this job.
    ///   - id: the job's ID, when the caller recorded it before queueing (an agent's request); a job with that ID
    ///     already queued is returned as it is.
    ///   - agent: the agent that queued it; such a job never passes the cap on its own (`overCapApproved` is
    ///     ignored) and is checked by the spending guard before its submit (`clearAgentSpend`).
    public func enqueue(
        _ spec: JobSpec, parentID: UUID? = nil, batchID: UUID? = nil, overCapApproved: Bool = false, id: UUID? = nil,
        agent: AgentOrigin? = nil
    ) async throws -> Job {
        let request = EnqueueRequest(spec: spec, parentID: parentID, agentRequest: agent?.requestID)
        if let running = enqueuing[request] { return try await running.value }
        let previous = lastEnqueue
        let approved = overCapApproved && agent == nil
        let task = Task {
            await previous?.value
            return try await self.insert(
                spec, parentID: parentID, batchID: batchID, overCapApproved: approved, id: id, agent: agent)
        }
        enqueuing[request] = task
        lastEnqueue = Task { _ = await task.result }
        defer { enqueuing[request] = nil }
        return try await task.value
    }

    /// A clip made from a start frame takes the frame's shape as its `aspectRatio`, the nearest fixed one: the
    /// account's Seedance doesn't derive it and makes 16:9 without one (REST's `image-to-video` does, and ignores
    /// it). A frame that can't be read leaves the server's default.
    /// The provider decides whether the job is paid from the unlimited allowance, not the caller: a spec
    /// copied from an earlier job may carry a choice that no longer holds. The cap doesn't count such a job.
    /// Such a job makes one variant, as the account caps it to; a job of several variants is a batch of its own
    /// unless it is part of one, so the jobs its submit starts are shown together.
    private func insert(
        _ spec: JobSpec, parentID: UUID?, batchID: UUID?, overCapApproved: Bool, id: UUID?, agent: AgentOrigin?
    ) async throws -> Job {
        if let id, let known = try? await loadJob(id) { return known }
        guard let provider else { throw JobEngineError.notConnected }
        var spec = spec
        if spec.usesFrames, spec.aspectRatio == nil || spec.aspectRatio == .auto, let start = spec.references.first {
            spec.aspectRatio = await media.imageSize(of: start).flatMap(AspectRatio.nearest(to:))
        }
        spec.usesUnlimited = await provider.paysUnlimited(spec)
        if spec.usesUnlimited { spec.variants = 1 }
        let cost = try await provider.estimate(spec)
        var job = Job(
            id: id ?? UUID(), spec: spec, providerKind: provider.kind, owner: provider.owner, parentID: parentID,
            batchID: batchID ?? (spec.variants > 1 ? UUID() : nil), cost: cost,
            createdAt: clock.now)
        job.agent = agent
        // What the user agreed to: a server price above it asks them again.
        if overCapApproved { job.approvedPrice = cost }
        if !spec.usesUnlimited, let status = try await spendStatus(job), !overCapApproved, let cap = status.cap,
            Budget.allows(cost: cost, committedToday: status.committedToday, cap: cap) != .allowed
        {
            throw JobEngineError.overCap(OverCap(cap: cap, committedToday: status.committedToday, price: cost))
        }
        try await repository.save(job)
        jobs[job.id] = job
        publish(job)
        startRunner(job.id)
        return job
    }
}
