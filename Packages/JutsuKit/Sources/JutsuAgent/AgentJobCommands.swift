import Foundation

// jobs and job_action: following the agents' work and acting on it. Their answers are in AgentVideo.swift.

/// The state of the named jobs, or of the agents' latest jobs; with `waitSeconds`, once they have all settled or the
/// wait is over, whichever comes first. A wait that runs out returns the state as it is and stops nothing.
public struct JobsCommand: Codable, Equatable, Sendable {
    public static let maxIDs = 20
    public static let maxLimit = 50
    /// The longest wait: under the minute MCP clients usually allow a tool call.
    public static let maxWaitSeconds = 50

    public var ids: [UUID]
    /// Without `ids`: how many of the agents' latest jobs, newest first.
    public var limit: Int?
    public var waitSeconds: Int
    /// Without `ids`: the `nextCursor` of the page before.
    public var cursor: String?

    public init(ids: [UUID] = [], limit: Int? = nil, waitSeconds: Int = 0, cursor: String? = nil) {
        self.ids = ids
        self.limit = limit
        self.waitSeconds = waitSeconds
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case ids, limit, waitSeconds, cursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ids = try container.decodeIfPresent([UUID].self, forKey: .ids) ?? []
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        waitSeconds = try container.decodeIfPresent(Int.self, forKey: .waitSeconds) ?? 0
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        if let problem = Self.problem(idCount: ids.count, limit: limit, waitSeconds: waitSeconds, cursor: cursor) {
            throw AgentError.badRequest(problem)
        }
    }

    /// Why these fields can't be a `jobs` call; nil when they can. Shared by the helper, which checks the tool's
    /// arguments with it, and the app as it decodes the command.
    public static func problem(idCount: Int, limit: Int?, waitSeconds: Int, cursor: String?) -> String? {
        guard idCount <= maxIDs else { return "ids takes at most \(maxIDs) job IDs" }
        if let limit, !(1...maxLimit).contains(limit) { return "limit is 1 to \(maxLimit)" }
        if let problem = waitProblem(waitSeconds) { return problem }
        if let cursor {
            guard idCount == 0 else { return "cursor pages the latest jobs; leave out ids" }
            guard AgentNames.isValidCursor(cursor) else { return "cursor is a nextCursor from an earlier answer" }
        }
        return nil
    }

    /// Why a wait of `seconds` can't be asked for: `jobs`, `create_video` and the exports take the same.
    public static func waitProblem(_ seconds: Int) -> String? {
        (0...maxWaitSeconds).contains(seconds) ? nil : "wait_seconds is 0 to \(maxWaitSeconds)"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !ids.isEmpty { try container.encode(ids, forKey: .ids) }
        try container.encodeIfPresent(limit, forKey: .limit)
        if waitSeconds > 0 { try container.encode(waitSeconds, forKey: .waitSeconds) }
        try container.encodeIfPresent(cursor, forKey: .cursor)
    }
}

/// What `job_action` can do. None of them deletes anything.
public enum AgentJobAction: String, Codable, Sendable, CaseIterable {
    case cancel, retry
    case runNext = "run_next"
    case pauseQueue = "pause_queue"
    case resumeQueue = "resume_queue"

    /// The actions on one job, which need its ID; the queue's take none.
    public var needsJob: Bool { self == .cancel || self == .retry || self == .runNext }
}

public struct JobActionCommand: Codable, Equatable, Sendable {
    public var action: AgentJobAction
    public var job: UUID?

    public init(action: AgentJobAction, job: UUID? = nil) {
        self.action = action
        self.job = job
    }

    private enum CodingKeys: String, CodingKey {
        case action, job
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(AgentJobAction.self, forKey: .action)
        job = try container.decodeIfPresent(UUID.self, forKey: .job)
        if let problem = Self.problem(action: action, hasJob: job != nil) { throw AgentError.badRequest(problem) }
    }

    /// Why `action` can't go with a job, or without one; nil when it can. Shared by the helper and the app.
    public static func problem(action: AgentJobAction, hasJob: Bool) -> String? {
        guard action.needsJob != hasJob else { return nil }
        return action.needsJob
            ? "\(action.rawValue) needs job, a job ID" : "\(action.rawValue) acts on the whole queue and takes no job"
    }
}
