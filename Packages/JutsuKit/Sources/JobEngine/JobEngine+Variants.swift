import Foundation
import JutsuCore

// One submit of several variants (`JobSpec.variants`) becomes one job per variant the answer started.
extension JobEngine {
    /// What the job that sent a submit of variants keeps for itself: its share of the request's price, the batch
    /// its variants joined, and how many variants the answer didn't start.
    struct VariantShare {
        var cost: Cost
        var serverPrice: Cost?
        var approvedPrice: Cost?
        var batchID: UUID?
        var variantGroupID: UUID?
        var missing: Int?

        /// From here on the job is one variant: a retry of it makes one.
        func apply(to job: inout Job) {
            job.cost = cost
            job.serverPrice = serverPrice
            job.approvedPrice = approvedPrice
            job.batchID = batchID
            job.variantGroupID = variantGroupID
            job.missingVariants = missing
            job.spec.variants = 1
        }
    }

    /// Makes a job of each further variant the submit of `sender` started (`others`) and returns what `sender`
    /// keeps, for its `.submitted`. Every variant was paid for, so each is saved and polled before `sender` takes
    /// its own answer: a crash in between leaves them tracked, and `sender`'s unanswered submit fails as unknown
    /// without being sent again. A variant that can't be saved still runs and is saved with its next change.
    ///
    /// The request's price is for every variant it asked for; each job takes an even share of it (`Cost.split`),
    /// so the jobs together count what the variants cost. Variants the answer didn't start count nothing and are
    /// noted on `sender` (`Job.missingVariants`).
    func startVariants(
        _ others: [RemoteJob], of sender: Job, inputs: RemoteInputs, paidWithUnlimited: Bool
    ) async -> VariantShare {
        let asked = max(sender.spec.variants, 1)
        let started = 1 + others.count
        let costs = sender.cost.split(into: asked)
        let quotes = sender.serverPrice?.split(into: asked)
        let approvals = sender.approvedPrice?.split(into: asked)
        // A variant past the ones asked for is still a paid job; it takes a share like the last one.
        func share(_ parts: [Cost], _ index: Int) -> Cost { parts[min(index, parts.count - 1)] }
        let batchID = sender.batchID ?? (others.isEmpty ? nil : UUID())
        let now = clock.now
        for (offset, remote) in others.enumerated() {
            let index = offset + 1
            var spec = sender.spec
            spec.variants = 1
            if !paidWithUnlimited { spec.usesUnlimited = false }
            var job = Job(
                spec: spec, providerKind: sender.providerKind, owner: sender.owner, parentID: sender.parentID,
                batchID: batchID, cost: share(costs, index), createdAt: sender.createdAt)
            job.state = .queued
            job.variantGroupID = sender.variantGroupID ?? sender.idempotencyKey
            job.serverPrice = quotes.map { share($0, index) }
            job.approvedPrice = approvals.map { share($0, index) }
            job.inputs = inputs
            job.remote = remote
            job.submittedAt = now
            // The sender's reservation pays for the whole submit.
            job.agent = sender.agent.map {
                var origin = $0
                origin.reservation = nil
                origin.hold = nil
                return origin
            }
            do {
                try await repository.save(job)
            } catch {
                log.error("Job \(job.id), a variant of \(sender.id): saving failed", detail: String(describing: error))
            }
            jobs[job.id] = job
            publish(job)
            startRunner(job.id)
        }
        if started < asked {
            log.error("Job \(sender.id): \(asked) variants asked for, the answer started \(started)")
        }
        return VariantShare(
            cost: costs[0], serverPrice: quotes?[0], approvedPrice: approvals?[0], batchID: batchID,
            variantGroupID: asked > 1 ? (sender.variantGroupID ?? sender.idempotencyKey) : sender.variantGroupID,
            missing: started < asked ? asked - started : nil)
    }
}
