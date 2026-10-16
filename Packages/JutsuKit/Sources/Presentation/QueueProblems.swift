import Foundation
import JutsuCore

/// The Queue's "Didn't finish" section: failed, rejected and canceled jobs, read from the store so they stay
/// there however many jobs finish after them and across launches, until the user removes them. Removing hides a
/// job from the Queue only; its record, its cost in today's spend and its IDs stay in the store.
public struct QueueProblems: Sendable, Equatable {
    /// How many such jobs the Queue loads from the store, newest first, removed ones included.
    public static let storedLimit = 100

    /// Jobs that finished at or before this were cleared with "Clear all"; `nil` when never cleared.
    public var clearedAt: Date?
    /// Jobs removed one by one since `clearedAt`.
    public var removed: Set<UUID>

    /// - Parameters:
    ///   - clearedAt: the stored `AppSettings.queueProblemsClearedAtKey` value, seconds since 1970, 0 for never.
    ///   - removed: the stored `AppSettings.queueRemovedProblemsKey` value.
    public init(clearedAt: Double, removed: String) {
        self.clearedAt = clearedAt > 0 ? Date(timeIntervalSince1970: clearedAt) : nil
        self.removed = Set(removed.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    /// `clearedAt` as stored, seconds since 1970, 0 for never.
    public var storedClearedAt: Double {
        clearedAt?.timeIntervalSince1970 ?? 0
    }

    /// `removed` as stored: ids separated by commas, sorted so an unchanged set writes the same value.
    public var storedRemoved: String {
        removed.map(\.uuidString).sorted().joined(separator: ",")
    }

    /// The jobs the section is about: finished, but not done.
    public static func isProblem(_ state: JobState) -> Bool {
        state.isTerminal && state != .done
    }

    /// Whether the section shows `job`: a problem the user hasn't cleared or removed.
    public func shows(_ job: Job) -> Bool {
        guard Self.isProblem(job.state), !removed.contains(job.id) else { return false }
        guard let clearedAt else { return true }
        return (job.finishedAt ?? job.createdAt) > clearedAt
    }

    /// Hides `id`. Forgets removed ids no longer among `loaded`, the jobs the store returned: past the newest
    /// `storedLimit` they can't be shown again, so the stored list stays as short as the section.
    public mutating func remove(_ id: UUID, loaded: some Sequence<UUID>) {
        removed = removed.intersection(loaded).union([id])
    }

    /// Hides every job finished until `now`. Jobs that fail later, a retried one included, show again.
    public mutating func clearAll(now: Date = .now) {
        clearedAt = now
        removed = []
    }
}

extension LiveJobs {
    /// The "Didn't finish" section: the problems among `stored` and the live jobs, each in its latest known
    /// version, newest finished first, a batch under one header. Leaves out the batches Active shows whole.
    /// - Parameter stored: the newest failed, rejected and canceled jobs from the store.
    public func problemEntries(stored: [Job], problems: QueueProblems) -> [QueueEntry] {
        var latest: [UUID: Job] = [:]
        for job in stored { latest[job.id] = self.job(job.id) ?? job }
        for job in recentFinished(limit: .max) where QueueProblems.isProblem(job.state) {
            latest[job.id] = job
        }
        let activeBatches = activeBatchIDs
        let shown = latest.values.filter { problems.shows($0) && $0.batchID.map(activeBatches.contains) != true }
        return QueueEntry.group(shown.sorted(by: Self.newestFinishedFirst))
    }
}
