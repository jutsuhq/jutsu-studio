import Foundation
import JutsuCore
import SwiftData

/// A persisted `Job`. The whole job is stored as JSON in `jobData`, so `Job` stays the single source of truth;
/// the other columns are copies kept only so `@Query` and fetches can filter and sort on them.
@Model
public final class JobRecord {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var createdAt: Date
    public private(set) var finishedAt: Date?
    /// `JobState` case name without its payload, e.g. "done" or "failed".
    public private(set) var stateKind: String
    public private(set) var isTerminal: Bool
    public private(set) var isDraft: Bool
    public private(set) var modeRaw: String
    public private(set) var resolutionRaw: String
    public private(set) var providerKindRaw: String
    public private(set) var prompt: String
    public private(set) var outputPath: String?
    public private(set) var jobData: Data
    /// Input versions pinned when first enqueued, independently of later execution updates.
    public private(set) var inputReferences: Data
    public private(set) var remoteKey: String?

    public init(job: Job, inputs: [MaterialInput] = []) throws {
        let data = try encodeJob(job)
        id = job.id
        createdAt = job.createdAt
        finishedAt = job.finishedAt
        stateKind = job.state.storageKind
        isTerminal = job.state.isTerminal
        isDraft = job.spec.isDraft
        modeRaw = job.spec.mode.rawValue
        resolutionRaw = job.spec.resolution.rawValue
        providerKindRaw = job.providerKind.rawValue
        prompt = job.spec.prompt
        outputPath = job.outputFile?.path(percentEncoded: false)
        jobData = data
        inputReferences = try JSONEncoder().encode(inputs)
        remoteKey = job.remote.map {
            MaterialRemote(provider: job.providerKind, owner: job.owner, id: $0.requestID).key
        }
    }

    /// The stored job.
    public func job() throws -> Job {
        try JSONDecoder().decode(Job.self, from: jobData)
    }

    /// Replaces the stored job and its query columns. The id never changes.
    public func update(from job: Job) throws {
        guard job.id == id else { throw PersistenceError.jobIDMismatch }
        let data = try encodeJob(job)
        createdAt = job.createdAt
        finishedAt = job.finishedAt
        stateKind = job.state.storageKind
        isTerminal = job.state.isTerminal
        isDraft = job.spec.isDraft
        modeRaw = job.spec.mode.rawValue
        resolutionRaw = job.spec.resolution.rawValue
        providerKindRaw = job.providerKind.rawValue
        prompt = job.spec.prompt
        outputPath = job.outputFile?.path(percentEncoded: false)
        jobData = data
        remoteKey = job.remote.map {
            MaterialRemote(provider: job.providerKind, owner: job.owner, id: $0.requestID).key
        }
    }

    /// Unfinished jobs and jobs finished at or after `date`: a superset of what the daily spend cap counts.
    /// A `@Query` with it updates whenever one of those jobs changes.
    public static func unfinishedOrFinished(since date: Date) -> Predicate<JobRecord> {
        let unfinished = Date.distantPast
        return #Predicate<JobRecord> { record in
            record.isTerminal == false || (record.finishedAt ?? unfinished) >= date
        }
    }

    /// Terminal jobs (done, failed, rejected, canceled), newest first: the library.
    public static var finishedNewestFirst: FetchDescriptor<JobRecord> {
        FetchDescriptor<JobRecord>(
            predicate: #Predicate<JobRecord> { $0.isTerminal == true },
            sortBy: [SortDescriptor(\JobRecord.createdAt, order: .reverse)])
    }

    /// Failed, rejected and canceled jobs finished after `date`, newest finished first, at most `limit`:
    /// the Queue's "Didn't finish" section.
    public static func problemsNewestFirst(finishedAfter date: Date?, limit: Int) -> FetchDescriptor<JobRecord> {
        let done = JobState.done.storageKind
        let since = date ?? .distantPast
        let unfinished = Date.distantPast
        var descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate<JobRecord> { record in
                record.isTerminal == true && record.stateKind != done && (record.finishedAt ?? unfinished) > since
            },
            sortBy: [SortDescriptor(\JobRecord.finishedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return descriptor
    }
}

public enum PersistenceError: Error, Equatable {
    case jobIDMismatch
}

private func encodeJob(_ job: Job) throws -> Data {
    try JSONEncoder().encode(job)
}

extension JobState {
    var storageKind: String {
        switch self {
        case .preparing: "preparing"
        case .uploading: "uploading"
        case .waitingForSlot: "waitingForSlot"
        case .queued: "queued"
        case .processing: "processing"
        case .downloading: "downloading"
        case .done: "done"
        case .failed: "failed"
        case .rejected: "rejected"
        case .canceled: "canceled"
        case .paused: "paused"
        }
    }
}
