import Foundation
import JutsuCore

/// What makes an agent's paid request (`create_video`, `create_image`, `enhance`) run once for its `request_id`: the
/// same request sent while it runs waits for it, one recorded in `AgentRequestLog` answers with what it made, and the
/// ID sent with other parameters is refused. A request is recorded by the run itself (`record`), with the IDs of what
/// it makes, before anything is queued or sent, and forgotten when it fails, so the agent can fix it and send it again.
@MainActor
public final class AgentRequestGate<Answer: Sendable, Failure: Error> {
    /// What a request is, by its ID and fingerprint.
    public enum State: Sendable, Hashable {
        /// Never seen: run it.
        case new
        /// The same request is running: it waits for that one.
        case running
        /// The same request again: these are what it made.
        case known([UUID])
        /// The ID was used with other parameters.
        case conflict
    }

    /// The failures the gate answers with instead of running a request.
    public struct Refusals: Sendable {
        /// The ID was used with other parameters.
        public var conflict: Failure
        /// The log can't be read, so whether the request ran isn't known.
        public var unreadable: Failure
        /// The request was recorded, but what it makes was never saved: nothing was queued or paid, so it is
        /// forgotten and may be sent again.
        public var neverQueued: Failure

        public init(conflict: Failure, unreadable: Failure, neverQueued: Failure) {
            self.conflict = conflict
            self.unreadable = unreadable
            self.neverQueued = neverQueued
        }
    }

    private let log: AgentRequestLog
    private let events = EngineLog(category: "Agents")
    private var running: [String: (fingerprint: String, task: Task<Result<Answer, Failure>, Never>)] = [:]

    public init(log: AgentRequestLog) {
        self.log = log
    }

    public func state(of requestID: String, fingerprint: String) throws(LogWriteError) -> State {
        if let running = running[requestID] { return running.fingerprint == fingerprint ? .running : .conflict }
        switch try log.lookup(requestID, fingerprint: fingerprint) {
        case .new: return .new
        case .known(let ids): return .known(ids)
        case .conflict: return .conflict
        }
    }

    /// Runs `queue` for a new request and answers with what it made. The same request running answers with what that
    /// run makes; one recorded answers with `known` for the IDs it recorded, or `refusals.neverQueued` when `known`
    /// finds none of them. `discard` is called once the request's own files aren't needed: refused, already known,
    /// joining the run in flight, whose own files are the ones it reads, or failed. A run that fails is forgotten.
    public func run(
        _ requestID: String, fingerprint: String, refusals: Refusals, discard: () -> Void,
        known: ([UUID]) async throws(Failure) -> Answer?,
        queue: @escaping @MainActor () async throws(Failure) -> Answer
    ) async throws(Failure) -> Answer {
        if let running = running[requestID] {
            guard running.fingerprint == fingerprint else {
                discard()
                throw refusals.conflict
            }
            discard()
            return try await running.task.value.get()
        }
        let lookup: AgentRequestLog.Lookup
        do {
            lookup = try log.lookup(requestID, fingerprint: fingerprint)
        } catch {
            events.error("The agent requests can't be read", detail: String(describing: error))
            throw refusals.unreadable
        }
        switch lookup {
        case .conflict:
            discard()
            throw refusals.conflict
        case .known(let ids):
            discard()
            if let answer = try await known(ids) { return answer }
            forget(requestID)
            throw refusals.neverQueued
        case .new:
            break
        }
        let task = Task { () -> Result<Answer, Failure> in
            do throws(Failure) {
                return .success(try await queue())
            } catch {
                return .failure(error)
            }
        }
        running[requestID] = (fingerprint, task)
        defer { running[requestID] = nil }
        let result = await task.value
        if case .failure = result {
            forget(requestID)
            discard()
        }
        return try result.get()
    }

    /// Records the request with the IDs of what it makes, before anything is queued or sent.
    public func record(_ requestID: String, fingerprint: String, ids: [UUID], at date: Date) throws(LogWriteError) {
        try log.add(
            AgentRequestLog.Record(requestID: requestID, fingerprint: fingerprint, jobIDs: ids, createdAt: date))
    }

    /// Forgets a request that queued nothing, so the agent can send it again. A log that can't be written keeps it,
    /// and the request sent again is then answered as never queued, and forgotten again.
    public func forget(_ requestID: String) {
        do {
            try log.remove(requestID)
        } catch {
            events.error("An agent request can't be forgotten", detail: String(describing: error))
        }
    }
}
