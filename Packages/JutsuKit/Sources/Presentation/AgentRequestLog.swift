import Foundation
import JutsuCore

/// The `request_id`s agents sent `create_video` with, and what each queued: what makes the same request sent again
/// return its job instead of paying for another. Written before the job is queued, with the job's ID chosen first, so
/// a crash in between still finds the job (or queues that same ID). Read strictly: a file that can't be read refuses
/// every request rather than forgetting which were made. Records are kept `keptDays` days.
@MainActor
public final class AgentRequestLog {
    public struct Record: Codable, Sendable, Hashable {
        public var requestID: String
        public var fingerprint: String
        public var jobIDs: [UUID]
        public var createdAt: Date

        public init(requestID: String, fingerprint: String, jobIDs: [UUID], createdAt: Date) {
            self.requestID = requestID
            self.fingerprint = fingerprint
            self.jobIDs = jobIDs
            self.createdAt = createdAt
        }
    }

    /// What a request is, by its ID and fingerprint.
    public enum Lookup: Sendable, Hashable {
        /// Never seen: queue it.
        case new
        /// The same request again: these are its jobs.
        case known([UUID])
        /// The ID was used with other parameters.
        case conflict
    }

    static let keptDays = 30

    private let file: LogFile<Record>
    private let now: () -> Date
    private var records: [Record]?

    /// - Parameter folder: `nil` keeps it in memory, for tests.
    public init(folder: URL?, now: @escaping () -> Date = { Date() }) {
        file = LogFile(folder: folder, name: "agent-requests.json")
        self.now = now
    }

    public func lookup(_ requestID: String, fingerprint: String) throws(LogWriteError) -> Lookup {
        guard let record = try load().first(where: { $0.requestID == requestID }) else { return .new }
        return record.fingerprint == fingerprint ? .known(record.jobIDs) : .conflict
    }

    /// Records a request before its jobs are queued.
    public func add(_ record: Record) throws(LogWriteError) {
        var records = try load()
        records.removeAll { $0.requestID == record.requestID }
        records.append(record)
        try save(records)
    }

    /// Forgets a request whose job couldn't be queued, so the agent can send it again.
    public func remove(_ requestID: String) throws(LogWriteError) {
        var records = try load()
        records.removeAll { $0.requestID == requestID }
        try save(records)
    }

    private func load() throws(LogWriteError) -> [Record] {
        if let records { return records }
        let loaded = try file.readStrict()
        records = loaded
        return loaded
    }

    private func save(_ updated: [Record]) throws(LogWriteError) {
        let cutoff = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        let kept = updated.filter { $0.createdAt >= cutoff }
        try file.write(kept)
        records = kept
    }
}
