import Foundation
import JutsuCore

/// What a submit just queued, shown for a moment wherever the user is: "Final queued · ~$0.68".
/// Every screen that queues a job shows this one, so a paid job is never queued without a word.
public struct QueuedNotice: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// "Final queued", "Draft queued" or "3 jobs queued".
    public let title: String
    /// The queued jobs' price, "~" first when it is an estimate; `nil` when their units differ.
    public let price: String?

    /// `nil` when nothing was queued.
    public init?(_ jobs: [Job], id: UUID = UUID()) {
        guard let first = jobs.first else { return nil }
        self.id = id
        if jobs.count > 1 {
            title = String(localized: "\(jobs.count) jobs queued", bundle: .module)
        } else {
            title = first.spec.isDraft ? Self.draftQueued : Self.finalQueued
        }
        let unknown = jobs.filter(\.priceIsUnknown)
        if unknown.isEmpty {
            price = Cost.total(jobs.map(\.price)).map { JobRowModel.format($0, charged: true) }
        } else {
            let afterRun = unknown.allSatisfy { $0.spec.operation?.action.isPricedAfterRun == true }
            price = afterRun ? PostOperationText.priceAfterRun : PostOperationText.priceUnknown
        }
    }

    /// "Final queued · ~$0.68".
    public var text: String {
        [title, price].compactMap { $0 }.joined(separator: " · ")
    }

    public static let finalQueued = String(localized: "Final queued", bundle: .module)
    public static let draftQueued = String(localized: "Draft queued", bundle: .module)
    public static let viewInQueue = String(localized: "View in Queue", bundle: .module)
    /// Render final's button while that final is in the queue.
    public static let finalQueuedViewInQueue = String(localized: "Final queued · View in Queue", bundle: .module)
    /// How long the notice stays up, in seconds.
    public static let duration: TimeInterval = 6
}

extension LiveJobs {
    /// The job still in the queue that was made from library item `parentID` with exactly `spec`, e.g. the final
    /// "Render final" queued at that resolution; `nil` once it finished.
    public func activeJob(parentID: UUID, spec: JobSpec) -> Job? {
        active.first { $0.parentID == parentID && $0.spec == spec }
    }
}
