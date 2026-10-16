import Foundation
import JutsuCore
import Observation

/// The latest known version of every job this session has seen, kept current from `JobEngine.events`.
/// Shared by the Queue screen, the sidebar badge and the menu bar. The engine sends a job on every
/// change, progress included, so views never poll.
@MainActor
@Observable
public final class LiveJobs {
    /// How many finished jobs the app loads from storage on launch, and keeps of those finished before today;
    /// the Queue shows fewer.
    public static let storedFinishedLimit = 50
    /// How many finished jobs the app loads from storage on launch for `generationTimes`.
    public static let generationHistoryLimit = 500

    private var jobs: [UUID: Job] = [:]
    /// Changes when a job is added or changes state, never for progress alone: observe it for what depends
    /// on states only.
    public private(set) var stateRevision = 0
    /// How long past jobs took to generate, from the loaded history and every job finished since.
    public private(set) var generationTimes = GenerationTimes()

    public init(_ jobs: [Job] = []) {
        seed(jobs)
    }

    /// Every job this session knows: the ones loaded on launch and every one the engine sent since.
    public var all: [Job] { Array(jobs.values) }

    /// Jobs still in the queue, paused ones included, oldest first.
    public var active: [Job] {
        jobs.values.filter(\.state.isActive).sorted { lhs, rhs in
            (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
        }
    }

    public var activeCount: Int {
        jobs.values.count(where: \.state.isActive)
    }

    /// Jobs whose submit is out and not answered yet; quitting now could cut it off.
    public var submittingCount: Int {
        jobs.values.count { $0.state == .waitingForSlot && $0.submitAttempt != nil }
    }

    /// Jobs the API has accepted and not finished; each holds one of the account's generation slots.
    public var busySlots: Int {
        jobs.values.count { $0.state == .queued || $0.state == .processing }
    }

    /// Pause all has a job to stop before it is submitted.
    public var canPauseAll: Bool {
        jobs.values.contains { $0.state.isPausableByUser }
    }

    /// Resume all has a job the user paused.
    public var canResumeAll: Bool {
        jobs.values.contains { $0.state == .paused(.byUser) }
    }

    /// "1 of 2 slots busy".
    public func slotsSummary(limit: Int) -> String {
        String(localized: "\(busySlots) of \(limit) slots busy", bundle: .module)
    }

    /// Done, failed, rejected and canceled jobs, most recently finished first.
    public func recentFinished(limit: Int) -> [Job] {
        let finished = jobs.values.filter(\.state.isTerminal).sorted(by: Self.newestFinishedFirst)
        return Array(finished.prefix(max(0, limit)))
    }

    /// The Queue's Active section: active jobs, oldest first, each batch under one header at its first job.
    /// A batch with any active job is shown here whole, finished jobs included, so its progress counts them.
    public var activeEntries: [QueueEntry] {
        let batches = activeBatchIDs
        let shown = jobs.values.filter { $0.state.isActive || $0.batchID.map(batches.contains) == true }
        return QueueEntry.group(shown.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })
    }

    /// The Queue's Finished section: the done jobs of `recentFinished` without the batches still shown as
    /// active, at most `limit` entries, a batch counting as one. Failed, rejected and canceled jobs have their
    /// own section (`problemEntries`), so newer results never push them out of reach.
    public func recentFinishedEntries(limit: Int) -> [QueueEntry] {
        let batches = activeBatchIDs
        let finished = recentFinished(limit: .max).filter {
            $0.state == .done && $0.batchID.map(batches.contains) != true
        }
        return Array(QueueEntry.group(finished).prefix(max(0, limit)))
    }

    /// Batches with a job still in the queue; Active shows them whole.
    var activeBatchIDs: Set<UUID> {
        Set(jobs.values.filter(\.state.isActive).compactMap(\.batchID))
    }

    public func job(_ id: UUID) -> Job? {
        jobs[id]
    }

    /// Replaces the job with the same id: the engine always sends the whole job.
    public func apply(_ job: Job) {
        let isNewState = jobs[job.id]?.state != job.state
        jobs[job.id] = job
        // Checked first: every assignment would invalidate the views reading the estimates.
        if generationTimes.needsRecording(job) { generationTimes.record([job]) }
        guard isNewState else { return }
        stateRevision += 1
        if job.state.isTerminal { dropOldFinished() }
    }

    /// Adds jobs loaded from storage. Never replaces one already here: an engine event may have
    /// arrived first and is newer than the stored copy.
    public func seed(_ stored: [Job]) {
        let new = stored.filter { jobs[$0.id] == nil }
        for job in new {
            jobs[job.id] = job
        }
        if !new.isEmpty { stateRevision += 1 }
        addHistory(stored)
    }

    /// Adds the timings of finished jobs loaded from storage to `generationTimes`, in one change.
    public func addHistory(_ history: [Job]) {
        let new = history.filter { generationTimes.needsRecording($0) }
        guard !new.isEmpty else { return }
        generationTimes.record(new)
    }

    /// Forgets what `oldFinished` picks, so a long session doesn't keep every job it has seen.
    private func dropOldFinished() {
        let old = Self.oldFinished(jobs.values, keeping: Self.storedFinishedLimit, now: .now)
        guard !old.isEmpty else { return }
        jobs = jobs.filter { !old.contains($0.key) }
    }

    /// Finished jobs past the newest `keep` that finished before `now`'s day, whose batch has nothing else left:
    /// today's spend counts the rest, and the Queue shows a batch whole.
    nonisolated static func oldFinished(
        _ jobs: some Collection<Job>, keeping keep: Int, now: Date, calendar: Calendar = .current
    ) -> Set<UUID> {
        let today = calendar.startOfDay(for: now)
        let old = jobs.filter(\.state.isTerminal).sorted(by: newestFinishedFirst).dropFirst(max(0, keep))
            .filter { ($0.finishedAt ?? $0.createdAt) < today }
        let dropped = Set(old.map(\.id))
        let keptBatches = Set(jobs.filter { !dropped.contains($0.id) }.compactMap(\.batchID))
        return Set(old.filter { $0.batchID.map(keptBatches.contains) != true }.map(\.id))
    }

    nonisolated static func newestFinishedFirst(_ lhs: Job, _ rhs: Job) -> Bool {
        let left = lhs.finishedAt ?? lhs.createdAt
        let right = rhs.finishedAt ?? rhs.createdAt
        return left != right ? left > right : lhs.id.uuidString > rhs.id.uuidString
    }

    /// Applies every event until the stream ends. Call once; the engine supports one consumer.
    /// `onFinished` runs for each event of a job that is done, failed, rejected or canceled.
    public func consume(_ events: AsyncStream<Job>, onFinished: @MainActor (Job) -> Void = { _ in }) async {
        for await job in events {
            apply(job)
            if job.state.isTerminal { onFinished(job) }
        }
    }
}
