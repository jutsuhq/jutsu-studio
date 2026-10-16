import Foundation
import JutsuCore

/// Cancel all on a Queue batch header: the batch's jobs that canceling still saves. Each goes through the engine's
/// cancel, like the row's own Cancel.
public struct BatchCancel: Sendable, Hashable {
    /// What Cancel all cancels, in queue order. A job Higgsfield is generating can't be canceled, and one that is
    /// downloading (or paused for disk space) is already charged, so stopping it saves nothing; both are left alone.
    public var jobs: [Job]
    /// How many of `jobs` were already sent to Higgsfield.
    public var submitted: Int

    public init(_ batch: JobBatch) {
        jobs = batch.jobs.filter { job in
            job.state.isCancellable && job.state != .downloading && job.state != .paused(.notEnoughDiskSpace)
        }
        submitted = jobs.count { $0.remote != nil || $0.submitAttempt != nil }
    }

    public var isEmpty: Bool { jobs.isEmpty }

    /// Asked first once any job is with Higgsfield; `nil` while none was sent, when canceling only drops them here.
    public var confirmation: Confirmation? {
        guard submitted > 0 else { return nil }
        return Confirmation(
            title: String(localized: "Cancel \(jobs.count) jobs?", bundle: .module),
            message: String(
                localized: """
                    \(submitted) of them are already with Higgsfield, which is asked to drop them. \
                    A job it already started can't be canceled and is charged.
                    """, bundle: .module),
            confirmTitle: String(localized: "Cancel \(jobs.count) Jobs", bundle: .module))
    }

    /// The alert after Cancel all: `nil` when every job was canceled; the engine's own alert when the only job
    /// refused; else "2 of 4 jobs weren't canceled" with the first reason.
    /// - Parameter refusals: what the engine said for each job it refused.
    public static func outcome(refusals: [UserMessage], of total: Int) -> UserMessage? {
        guard let first = refusals.first else { return nil }
        if total == 1 { return first }
        return UserMessage(
            title: String(localized: "\(refusals.count) of \(total) jobs weren't canceled", bundle: .module),
            message: "\(first.title). \(first.message)", action: first.action)
    }

    public struct Confirmation: Sendable, Hashable {
        public var title: String
        public var message: String
        public var confirmTitle: String
    }
}

/// Render finals for the starred drafts of a batch: one resolution for all of them, one price and one cap check
/// for the total. Each final links to its own draft, as a single Render final does.
public struct BatchFinals: Sendable, Hashable {
    /// One final to queue and the draft it is made from.
    public struct Final: Sendable, Hashable {
        public var spec: JobSpec
        /// The draft's id: the final's `Job.parentID`, which links the two in the chain.
        public var parentID: UUID
    }

    /// The starred drafts, in batch order. A result still only on Higgsfield gets its final from Edit Inputs.
    public var drafts: [LibraryItemModel]

    public init(_ batch: LibraryBatch) {
        self.init(batch.items)
    }

    public init(_ items: [LibraryItemModel]) {
        drafts = items.filter { $0.isStarred && $0.canRenderFinal && $0.historyItem == nil }
    }

    public var isEmpty: Bool { drafts.isEmpty }

    /// What the one resolution choice offers. A batch runs one model, so its drafts offer the same; an old Kling
    /// batch offers Pro only.
    public var resolutions: [Resolution] {
        drafts.first?.finalResolutions ?? []
    }

    /// The model the resolutions are named after.
    public var model: VideoModel? { drafts.first?.spec.model }

    /// Each draft's final at `resolution`, leaving out a final already in the queue: queueing it again would
    /// charge twice.
    /// A native draft of the signed-in account (`owner`) is finalized at 1080p rather than rendered again
    /// (`LibraryItemModel.finalSpec(at:owner:now:)`).
    /// - Parameter isQueued: whether the final with this spec, made from this draft, is still in the queue.
    public func finals(
        at resolution: Resolution, owner: String? = nil, now: Date = Date(),
        isQueued: (JobSpec, UUID) -> Bool = { _, _ in false }
    ) -> [Final] {
        drafts.map { Final(spec: $0.finalSpec(at: resolution, owner: owner, now: now), parentID: $0.id) }
            .filter { !isQueued($0.spec, $0.parentID) }
    }

    /// The finals' combined price: `nil` when any is unknown (an account's estimate that didn't come) or there
    /// are none, so the cap check asks rather than counts a part.
    public static func total(_ prices: [Cost?]) -> Cost? {
        let known = prices.compactMap { $0 }
        return known.count == prices.count ? Cost.total(known) : nil
    }

    /// The combined list price for an API key; `nil` for an account, whose credits only the provider estimates.
    public static func listPrice(of finals: [Final], pricing: Pricing?, connection: ProviderKind?) -> Cost? {
        guard connection == .apiKey, let pricing else { return nil }
        return total(finals.map { try? pricing.cost(for: $0.spec) })
    }

    /// The button: "Render 3 finals".
    public static func title(count: Int) -> String {
        String(localized: "Render \(count) finals", bundle: .module)
    }

    public static let menuTitle = String(localized: "Render Finals for Starred…", bundle: .module)
}
