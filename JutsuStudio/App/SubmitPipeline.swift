import Foundation
import JutsuCore
import Presentation

/// The enqueue shared by every screen that queues jobs: in order, the engine's error as an alert and the queued
/// notice once all are in, so no screen queues a paid job silently or drops an error. `SubmitController` decides
/// before it and asks about the cap; the pipeline only queues.
//
// Callers run it from a `SubmitController` submit, a task of its own on the main actor. Enqueues are user-initiated
// engine work and run on after navigation away; only the preview probe (Create) has a cancellation slot.
@MainActor
struct SubmitPipeline {
    let environment: AppEnvironment
    let connection: ConnectionStore

    /// Enqueues in order; the alert when a spec fails, saying how many were queued before it, `nil` when all
    /// queued. `batchID` is shared by the jobs of a batch, so the queue and the library group them.
    /// `overCapApproved` once the user confirmed going over today's cap; the engine refuses it otherwise.
    /// Once all are queued it shows what was queued and its price, so no screen queues a paid job silently.
    func enqueue(
        _ specs: [JobSpec], parentID: UUID? = nil, batchID: UUID? = nil, overCapApproved: Bool = false
    ) async -> UserMessage? {
        await enqueue(linked: specs.map { ($0, parentID) }, batchID: batchID, overCapApproved: overCapApproved)
    }

    /// `enqueue` for jobs made from different library items, e.g. the finals of several drafts, each linked to
    /// its own draft.
    func enqueue(
        linked jobs: [(spec: JobSpec, parentID: UUID?)], batchID: UUID? = nil, overCapApproved: Bool = false
    ) async -> UserMessage? {
        var queued: [Job] = []
        let error = await BatchEnqueue.run(jobs.map(\.spec), kind: connection.state.kind) { spec in
            // `BatchEnqueue` queues in order and stops at the first failure, so the next job is the next spec.
            let parentID = jobs[queued.count].parentID
            queued.append(
                try await environment.enqueue(
                    spec, parentID: parentID, batchID: batchID, overCapApproved: overCapApproved))
        }
        // The engine's event for a new job may arrive after this returns; seeding it now lets a screen see the job
        // as queued (e.g. Render final turning into "Final queued") before its button turns back on.
        environment.liveJobs.seed(queued)
        if error == nil { environment.navigation.queuedNotice = QueuedNotice(queued) }
        return error
    }
}
