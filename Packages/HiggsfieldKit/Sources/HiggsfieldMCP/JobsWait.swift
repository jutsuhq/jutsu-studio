import Foundation
import HiggsfieldCore

/// A `jobs_wait` answer: the statuses of up to `HiggsfieldAccount.jobsWaitLimit` jobs from one long-poll.
///
/// Live answers of 2026-10-15 (`docs/mcp-snapshots/live-2026-10-15/jobs_wait_*.json`) have the `outputSchema`'s
/// shape: `{jobs: [{index, job_id, status, type, model, result_url}], summary: {total, completed, failed, active,
/// errors}, all_terminal, timed_out, poll_after_seconds}`, `status` being `in_progress` while a job runs and
/// `completed` with its `result_url` once done. `type` isn't read: a running Seedance job says `image` and only a
/// completed one `video`. Other shapes are still read tolerantly (`docs/higgsfield-api.md` 4.4): the jobs as an array
/// under `jobs`,
/// `results`, `items`, `data` or `generations`, each with its ID in `job_id`, `id` or `jobId`, or as an object of
/// those keys by job ID; each job's status as `job_status` gives it, in the job itself or its `generation`, with the
/// file in `result_url` or `results.rawUrl`. A job is left out when its ID wasn't asked for, it has no `status`
/// string, its lookup failed (`lookup_failed`), or it is completed without an https file; the caller asks
/// `job_status` for it instead.
public struct JobsWait: Sendable, Hashable {
    /// By job ID.
    public var statuses: [String: GenerationStatus]
    /// When the server asks to be asked again, in seconds; `nil` when it doesn't say.
    public var pollAfterSeconds: Double?

    public init(statuses: [String: GenerationStatus], pollAfterSeconds: Double? = nil) {
        self.statuses = statuses
        self.pollAfterSeconds = pollAfterSeconds
    }

    init(answer: JSONValue, asked: Set<String>) {
        var statuses: [String: GenerationStatus] = [:]
        for (id, job) in Self.jobs(in: answer) where asked.contains(id) {
            let generation = job[ToolKey.generation].flatMap { $0.objectValue == nil ? nil : $0 } ?? job
            guard let text = generation[ToolKey.status]?.stringValue, text != Self.lookupFailed,
                let status = Self.status(of: generation, error: job[ToolKey.error])
            else { continue }
            statuses[id] = status
        }
        self.statuses = statuses
        pollAfterSeconds = answer[ToolKey.pollAfterSeconds]?.numberValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    static let listKeys = [ToolKey.jobs, ToolKey.results, ToolKey.items, ToolKey.data, "generations"]
    static let idKeys = [ToolKey.jobIDSingle, ToolKey.id, ToolKey.jobID]
    /// The status of a job the server couldn't look up, for now (`retryable`) or for good.
    static let lookupFailed = "lookup_failed"
    /// Where `jobs_wait` names a finished job's file; `job_status` has it in `results.rawUrl`.
    static let resultURL = "result_url"

    /// As `job_status` reads it, with the file in `result_url` when `results.rawUrl` is missing.
    static func status(of job: JSONValue, error: JSONValue?) -> GenerationStatus? {
        if job[ToolKey.status] == "completed", job[ToolKey.results]?[ToolKey.rawURL] == nil {
            return job[resultURL]?.stringValue.flatMap(URL.init(serverMedia:)).map { .completed(videoURL: $0) }
        }
        return HiggsfieldAccount.status(of: job, error: error)
    }

    /// Each job of the answer with its ID.
    static func jobs(in answer: JSONValue) -> [(String, JSONValue)] {
        for key in listKeys {
            if let list = answer[key]?.arrayValue {
                return list.compactMap { job in
                    idKeys.lazy.compactMap { job[$0]?.stringValue }.first.map { ($0, job) }
                }
            }
            if let byID = answer[key]?.objectValue {
                return byID.filter { $0.value.objectValue != nil }.map { ($0.key, $0.value) }
            }
        }
        return []
    }

    /// The `jobs` argument: each ID with its place in `ids` as the `index` the schema requires.
    static func arguments(_ ids: [String]) -> [String: JSONValue] {
        let jobs = ids.enumerated().map { index, id -> JSONValue in
            [ToolKey.jobIDSingle: .string(id), ToolKey.index: .number(Double(index))]
        }
        return [ToolKey.jobs: .array(jobs)]
    }
}

extension HiggsfieldAccount {
    /// How many jobs one `jobs_wait` call takes (its schema's `maxItems`).
    public static let jobsWaitLimit = 12

    /// One `jobs_wait` long-poll of `ids`, which the server holds for up to 15 s (`timeout_seconds` is left at its
    /// default, the maximum). `nil` when the account has no `jobs_wait` whose schema takes `jobs`, or `ids` is empty
    /// or longer than `jobsWaitLimit`. Read-only and free.
    public func waitForJobs(_ ids: [String]) async throws -> JobsWait? {
        guard !ids.isEmpty, ids.count <= Self.jobsWaitLimit,
            try await lookUp(.jobsWait, recheckingAfter: Self.optionalToolRecheck) != nil
        else { return nil }
        let answer = try await call(.jobsWait, JobsWait.arguments(ids))
        return JobsWait(answer: answer, asked: Set(ids))
    }
}
