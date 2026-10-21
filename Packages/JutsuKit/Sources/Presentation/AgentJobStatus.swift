import Foundation
import JutsuCore

/// A job as an agent's `jobs` sees it: stable snake_case names rather than the Queue's words, and whether only the
/// person can move it on.
public struct AgentJobStatus: Sendable, Hashable {
    public var state: String
    public var pauseReason: String?
    public var hold: String?
    public var needsPerson: Bool
    public var progress: Double?
    /// The best known price in whole units; `nil` when it isn't known.
    public var price: AgentMoney?
    public var isPriceExact: Bool
    /// Charged, or may have been.
    public var charged: Bool
    public var error: String?
    /// The finished video's path.
    public var result: String?

    public init(_ job: Job) {
        state = Self.name(of: job.state)
        if case .paused(let reason) = job.state {
            pauseReason = Self.name(of: reason)
            hold = reason == .agentLimit ? job.agent?.hold.map(Self.name(of:)) : nil
            needsPerson = reason != .byUser
        } else {
            needsPerson = false
        }
        if job.state.reportsProgress { progress = min(max(job.progress, 0), 1) }
        price = job.spec.usesUnlimited ? AgentMoney(.credits(0, isEstimate: false)) : AgentMoney(job.price)
        isPriceExact = job.agentPriceIsKnown
        charged = job.isCharged || job.mayHaveBeenCharged || job.submitAttempt != nil || job.remote != nil
        switch job.state {
        case .failed(let reason): error = reason.text
        case .rejected: error = job.rejection?.title ?? "Rejected by content moderation"
        default: error = nil
        }
        result = job.state == .done ? job.outputFile?.path(percentEncoded: false) : nil
    }

    public static func name(of state: JobState) -> String {
        switch state {
        case .preparing: "preparing"
        case .uploading: "uploading"
        case .waitingForSlot: "waiting_for_slot"
        case .queued: "queued"
        case .processing: "processing"
        case .downloading: "downloading"
        case .paused: "paused"
        case .done: "done"
        case .failed: "failed"
        case .rejected: "rejected"
        case .canceled: "canceled"
        }
    }

    public static func name(of reason: PauseReason) -> String {
        switch reason {
        case .insufficientFunds: "insufficient_funds"
        case .connectionNeedsAttention: "connection_needs_attention"
        case .priceAboveCap: "price_above_cap"
        case .notEnoughDiskSpace: "not_enough_disk_space"
        case .keptFailing: "kept_failing"
        case .byUser: "by_user"
        case .agentLimit: "agent_limit"
        }
    }

    public static func name(of hold: AgentHold) -> String {
        switch hold {
        case .unknownPrice: "unknown_price"
        case .overMaxCost: "over_max_cost"
        case .overDailyBudget: "over_daily_budget"
        case .ledgerUnavailable: "ledger_unavailable"
        }
    }

    /// Finished, or waiting for someone: a `jobs` wait ends once every job it names is.
    public static func isSettled(_ state: JobState) -> Bool {
        state.isTerminal || state.isPaused
    }
}

/// What an agent may do to a job with `job_action`, and why not. Only jobs an agent queued; nothing that could pay
/// twice; nothing that resumes a job waiting for the person.
public enum AgentJobRules {
    public static func cancelRefusal(_ job: Job) -> String? {
        if job.agent == nil { return "Only jobs an agent queued can be canceled by an agent." }
        return nil
    }

    public static func retryRefusal(_ job: Job) -> String? {
        if job.agent == nil { return "Only jobs an agent queued can be retried by an agent." }
        if job.mayHaveBeenCharged {
            return "The job may already have been charged; only the person can decide to retry it in the Queue."
        }
        return nil
    }

    public static func runNextRefusal(_ job: Job) -> String? {
        if job.agent == nil { return "Only jobs an agent queued can be moved ahead by an agent." }
        return nil
    }
}

/// Waits up to `seconds` for `isSettled`, checking every `milliseconds`; `true` when the time ran out first. Waiting
/// stops nothing.
public func agentWait(
    seconds: Int, milliseconds: Int = 500, isolation: isolated (any Actor)? = #isolation, isSettled: () async -> Bool,
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) async -> Bool {
    let step = max(1, milliseconds)
    if await isSettled() { return false }
    for _ in 0..<(max(0, seconds) * 1000 / step) {
        do { try await sleep(.milliseconds(step)) } catch { return true }
        if await isSettled() { return false }
    }
    return true
}
