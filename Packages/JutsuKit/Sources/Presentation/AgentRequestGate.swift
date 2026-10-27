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
        /// The same parameters with another `max_cost`: what it made, whose hold the new one may lift.
        case otherMaxCost([UUID])
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
    private let events = PresentationLog(category: "Agents")
    private var running: [String: (fingerprint: String, task: Task<Result<Answer, Failure>, Never>)] = [:]
    /// Raises of `max_cost` in flight (`otherMaxCost`), by request ID and the fingerprint of the new `max_cost`.
    private var raising: [Raise: Task<Result<Answer, Failure>, Never>] = [:]

    private struct Raise: Hashable {
        var requestID: String
        var fingerprint: String
    }

    public init(log: AgentRequestLog) {
        self.log = log
    }

    public func state(
        of requestID: String, fingerprint: String, parameters: String? = nil
    ) throws(LogWriteError) -> State {
        if let running = running[requestID] { return running.fingerprint == fingerprint ? .running : .conflict }
        switch try log.lookup(requestID, fingerprint: fingerprint, parameters: parameters) {
        case .new: return .new
        case .known(let ids): return .known(ids)
        case .otherMaxCost(let ids): return .otherMaxCost(ids)
        case .conflict: return .conflict
        }
    }

    /// Runs `queue` for a new request and answers with what it made. The same request running answers with what that
    /// run makes; one recorded answers with `known` for the IDs it recorded, or `refusals.neverQueued` when `known`
    /// finds none of them. One recorded with the same `parameters` and another `max_cost` answers with what
    /// `otherMaxCost` makes of what it recorded, `refusals.conflict` when it isn't liftable or not given, and
    /// `refusals.neverQueued` (forgotten, as for `known`) when its job isn't there; the same request sent again while
    /// that runs joins it. `discard` is called once the request's own files aren't needed:
    /// refused, already known, joining the run in flight, whose own files are the ones it reads, or failed. A run that
    /// fails is forgotten.
    public func run(
        _ requestID: String, fingerprint: String, parameters: String? = nil, refusals: Refusals, discard: () -> Void,
        known: ([UUID]) async throws(Failure) -> Answer?,
        otherMaxCost: (@MainActor ([UUID]) async throws(Failure) -> AgentRaiseOutcome<Answer>)? = nil,
        queue: @escaping @MainActor () async throws(Failure) -> Answer
    ) async throws(Failure) -> Answer {
        if let running = running[requestID] {
            discard()
            guard running.fingerprint == fingerprint else { throw refusals.conflict }
            return try await running.task.value.get()
        }
        let raise = Raise(requestID: requestID, fingerprint: fingerprint)
        if let raising = raising[raise] {
            discard()
            return try await raising.value.get()
        }
        let lookup: AgentRequestLog.Lookup
        do {
            lookup = try log.lookup(requestID, fingerprint: fingerprint, parameters: parameters)
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
        case .otherMaxCost(let ids):
            discard()
            guard let otherMaxCost else { throw refusals.conflict }
            return try await run(raise, of: ids, refusals: refusals, otherMaxCost)
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

    /// Runs `otherMaxCost` for the request sent again with another `max_cost`, so the same one sent meanwhile joins
    /// it instead of checking the job a second time.
    private func run(
        _ raise: Raise, of ids: [UUID], refusals: Refusals,
        _ otherMaxCost: @escaping @MainActor ([UUID]) async throws(Failure) -> AgentRaiseOutcome<Answer>
    ) async throws(Failure) -> Answer {
        let task = Task { () -> Result<Answer, Failure> in
            do throws(Failure) {
                switch try await otherMaxCost(ids) {
                case .answer(let answer): return .success(answer)
                case .notLiftable: return .failure(refusals.conflict)
                case .gone:
                    forget(raise.requestID)
                    return .failure(refusals.neverQueued)
                }
            } catch {
                return .failure(error)
            }
        }
        raising[raise] = task
        defer { raising[raise] = nil }
        return try await task.value.get()
    }

    /// Records the request with the IDs of what it makes, before anything is queued or sent.
    /// - Parameter kind: what the IDs are when the app keeps them only in memory (`AgentRequestLog.Record.kind`).
    public func record(
        _ requestID: String, fingerprint: String, parameters: String? = nil, ids: [UUID], at date: Date,
        kind: String? = nil
    ) throws(LogWriteError) {
        try log.add(
            AgentRequestLog.Record(
                requestID: requestID, fingerprint: fingerprint, parameters: parameters, jobIDs: ids, createdAt: date,
                kind: kind))
    }

    /// The `kind` the request that made `id` was recorded with.
    public func kind(of id: UUID) -> String? { log.kind(of: id) }

    /// The request sent again with another `max_cost` lifted its job's hold: from now on that one is the request.
    public func update(_ requestID: String, fingerprint: String) throws(LogWriteError) {
        try log.update(requestID, fingerprint: fingerprint)
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

/// What a request sent again with another `max_cost` made of what it recorded (`AgentRequestGate.run`'s
/// `otherMaxCost`).
public enum AgentRaiseOutcome<Answer: Sendable>: Sendable {
    /// The answer for the job: lifted, still held, or already raised to this `max_cost`.
    case answer(Answer)
    /// Nothing the new `max_cost` can lift: refused as a conflict.
    case notLiftable
    /// The job it recorded isn't there: answered as never queued, and the request forgotten.
    case gone

    public func map<Other: Sendable>(_ transform: (Answer) -> Other) -> AgentRaiseOutcome<Other> {
        switch self {
        case .answer(let answer): .answer(transform(answer))
        case .notLiftable: .notLiftable
        case .gone: .gone
        }
    }
}

extension AgentRaiseOutcome: Equatable where Answer: Equatable {}
