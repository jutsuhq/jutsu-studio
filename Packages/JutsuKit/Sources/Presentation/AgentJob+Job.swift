import Foundation
import JutsuAgent
import JutsuCore

extension AgentJob {
    /// A video job as an agent's `jobs` sees it: stable snake_case names rather than the Queue's words, and whether
    /// only the person can move it on.
    public init(_ job: Job) {
        self.init(
            id: job.id, state: Self.name(of: job.state), requestID: job.agent?.requestID, client: job.agent?.client,
            mode: AgentVideoOrder.name(of: job.spec.mode), model: job.spec.model.rawValue,
            next: AgentJobRules.checkHint(job), createdAt: job.createdAt, finishedAt: job.finishedAt)
        if case .paused(let reason) = job.state {
            pauseReason = Self.name(of: reason)
            hold = reason == .agentLimit ? job.agent?.hold.map(Self.name(of:)) : nil
            needsPerson = reason != .byUser
        }
        if job.state.reportsProgress { progress = min(max(job.progress, 0), 1) }
        price = (job.spec.usesUnlimited ? AgentMoney(.credits(0, isEstimate: false)) : AgentMoney(job.price))
            .map(AgentAmount.init)
        isPriceExact = job.agentPriceIsKnown
        charged = job.isCharged || job.mayHaveBeenCharged || job.submitAttempt != nil || job.remote != nil
        switch job.state {
        case .failed(let reason): error = reason.text
        case .rejected:
            error = job.rejection?.title ?? String(localized: "Rejected by content moderation", bundle: .module)
        default: error = nil
        }
        result = job.state == .done ? job.outputFile?.path(percentEncoded: false) : nil
        if job.state == .done, let media = job.outputMedia {
            width = media.pixelSize.width
            height = media.pixelSize.height
            duration = media.duration
            frameNote = AgentJobRules.frameNote(source: job.spec.source?.pixelSize, result: media.pixelSize)
        }
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
        case .unlimitedNotAllowed: "unlimited_not_allowed"
        case .aboveApprovedPrice: "above_approved_price"
        }
    }

    /// Finished, or waiting for someone: a `jobs` wait ends once every job it names is.
    public static func isSettled(_ state: JobState) -> Bool {
        state.isTerminal || state.isPaused
    }

    /// The price is known as the spending guard reads it, or the job got past the guard, or it was held or finished:
    /// a `create_video` wait ends once every job it queued is. A known price can still be held at submit, above
    /// max_cost or the budgets; the agent sees both in the answer.
    public static func isPriced(_ job: Job) -> Bool {
        isSettled(job.state) || job.agentPriceIsKnown || job.submitAttempt != nil || job.remote != nil
    }
}

/// What an agent may do to a job with `job_action`, and why not. Only jobs an agent queued; nothing that could pay
/// twice; nothing that resumes a job waiting for the person.
public enum AgentJobRules {
    public static func cancelRefusal(_ job: Job) -> String? {
        if job.agent == nil { return "Only jobs an agent queued can be canceled by an agent." }
        return nil
    }

    /// - Parameter fileExists: whether a local input is still there; an agent's uploads are swept from the inbox a
    ///   day after their job finished, and a retry without them would only fail once it runs.
    public static func retryRefusal(_ job: Job, fileExists: (URL) -> Bool = { _ in true }) -> String? {
        if job.agent == nil { return "Only jobs an agent queued can be retried by an agent." }
        if job.mayHaveBeenCharged {
            return "The job may already have been charged; only the person can decide to retry it in the Queue."
        }
        let inputs = [job.spec.source?.fileURL].compactMap(\.self) + job.spec.references.map(\.fileURL)
        if inputs.contains(where: { $0.isFileURL && !fileExists($0) }) {
            return "The job's input files are gone from Jutsu Studio, so a retry can't run. Send create_video again "
                + "with the files and a new request_id."
        }
        return nil
    }

    public static func runNextRefusal(_ job: Job) -> String? {
        if job.agent == nil { return "Only jobs an agent queued can be moved ahead by an agent." }
        return nil
    }

    /// For a finished video: how to look at it with `frames`, against its own source when it has one, rather than
    /// grabbing frames by hand.
    public static func checkHint(_ job: Job) -> String? {
        guard job.state == .done, job.outputFile != nil else { return nil }
        let item = job.id.uuidString
        return job.spec.source == nil
            ? "To check it, call frames with item \(item) and a few times; it writes the frames and a contact sheet."
            : "To check it against its source, call frames with item \(item), a few times and compare_source true; "
                + "it writes both clips' frames side by side on a contact sheet."
    }

    /// Says so when a finished video's frame isn't its source's shape: Genjutsu Lite takes no aspect ratio and once
    /// made a 3:4 draft (554×740) from a 9:16 source, which an agent scaled to 1080×1920 and stretched. Shapes within
    /// 2 % of each other are the same frame, as `PixelSize.aspectLabel` names them.
    public static func frameNote(source: PixelSize?, result: PixelSize) -> String? {
        guard let source, source.isValid, result.isValid else { return nil }
        let difference =
            log(Double(result.width) / Double(result.height))
            - log(Double(source.width) / Double(source.height))
        guard abs(difference) >= 0.02 else { return nil }
        let shape = { (size: PixelSize) in "\(size.width)×\(size.height) (\(size.aspectLabel ?? "?"))" }
        return "The result is \(shape(result)), not the source's frame, \(shape(source)): the model chose its own. "
            + "Scaling it to the source's frame stretches it; check it with frames, then crop it (delivery_set) or "
            + "make it again."
    }

    /// Why a job sent again with a higher `max_cost` still waits: the hold it would get now, or `nil` for the
    /// person's daily cap. Nothing changed, so the job stays held over its old `max_cost`, which the same request can
    /// lift later, once the budget or the cap has room.
    public static func stillHeldNote(_ hold: AgentHold?) -> String {
        switch hold {
        case .overMaxCost:
            "The price is still above max_cost. Send the request again with a max_cost of at least the price, or ask "
                + "the person to confirm it in the Queue."
        case .overDailyBudget:
            "The price is more than is left of today's agent budget, so the job stays held over its old max_cost. "
                + "Send the request again once the budget has room (tomorrow, or after the person raises it in "
                + "Settings › Agents), or ask the person to confirm it in the Queue."
        case nil:
            "The price would take today's spending over the person's daily cap, so the job stays held over its old "
                + "max_cost. Send the request again once the cap has room, or ask the person to confirm it in the "
                + "Queue."
        case .unknownPrice, .ledgerUnavailable, .unlimitedNotAllowed, .aboveApprovedPrice:
            "The job can't be checked against the new max_cost now, so it stays held over its old max_cost. Send the "
                + "request again in a moment, or ask the person to confirm it in the Queue."
        }
    }
}

/// A page of the agents' jobs, newest first, after a cursor an earlier page handed out.
public enum AgentJobPage {
    /// - Returns: the jobs of the page, and the cursor of the next one when there are more.
    public static func page(_ jobs: [Job], limit: Int, after cursor: String?) -> (jobs: [Job], next: String?) {
        let agents = jobs.filter { $0.agent != nil }
        let byID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let (ids, next) = page(agents.map { ($0.createdAt, $0.id) }, limit: limit, after: cursor)
        return (ids.compactMap { byID[$0] }, next)
    }

    /// The same page over entries of any kind, by when each was made and its ID: video jobs and image requests.
    public static func page(
        _ entries: [(Date, UUID)], limit: Int, after cursor: String?
    ) -> (ids: [UUID], next: String?) {
        let sorted = entries.sorted(by: AgentCursor.isNewerFirst)
        let rest =
            cursor.flatMap(AgentCursor.init(text:)).map { position in
                sorted.filter { position.precedes($0.0, $0.1) }
            } ?? sorted
        let page = Array(rest.prefix(max(1, limit)))
        let next = rest.count > page.count ? page.last.map { AgentCursor($0.0, $0.1).text } : nil
        return (page.map(\.1), next)
    }
}

/// Where a page newest first ended: the date and ID of its last entry, as text an agent hands back
/// (`1729500000123_<UUID>`). Entries order by date, then by ID, so equal dates never repeat or drop one.
public struct AgentCursor: Sendable, Hashable {
    public var date: Date
    public var id: UUID

    public init(_ date: Date, _ id: UUID) {
        self.date = date
        self.id = id
    }

    /// `nil` for text no page handed out.
    public init?(text: String) {
        let parts = text.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let milliseconds = Int64(parts[0]), let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        self.init(Date(timeIntervalSince1970: Double(milliseconds) / 1000), id)
    }

    public var text: String { "\(Self.milliseconds(date))_\(id.uuidString)" }

    /// Whether an entry made at `date` with `id` comes after this cursor, newest first.
    public func precedes(_ date: Date, _ id: UUID) -> Bool {
        let (mine, theirs) = (Self.milliseconds(self.date), Self.milliseconds(date))
        return theirs != mine ? theirs < mine : id.uuidString < self.id.uuidString
    }

    /// Newest first, then by ID, to the millisecond a cursor keeps.
    public static func isNewerFirst(_ a: Job, _ b: Job) -> Bool {
        isNewerFirst((a.createdAt, a.id), (b.createdAt, b.id))
    }

    public static func isNewerFirst(_ a: (Date, UUID), _ b: (Date, UUID)) -> Bool {
        let (left, right) = (milliseconds(a.0), milliseconds(b.0))
        return left != right ? left > right : a.1.uuidString > b.1.uuidString
    }

    static func milliseconds(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.down)
        return value.isFinite ? Int64(clamping: Int(max(min(value, 9e15), -9e15))) : 0
    }
}

/// Waits up to `seconds` for `isSettled`, checking every `milliseconds`; `true` when the time ran out first. Waiting
/// stops nothing. The time is read from the clock rather than counted in checks: in the background (App Nap) each
/// sleep runs long, and a wait that counted 100 of them overran `AgentProtocol.answerDeadline`, so `jobs` answered
/// still_working instead of timedOut.
public func agentWait(
    seconds: Int, milliseconds: Int = 500, isolation: isolated (any Actor)? = #isolation, isSettled: () async -> Bool,
    now: () -> ContinuousClock.Instant = { .now },
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) async -> Bool {
    let step = Duration.milliseconds(max(1, milliseconds))
    let deadline = now() + .seconds(max(0, seconds))
    if await isSettled() { return false }
    while now() < deadline {
        do { try await sleep(min(step, deadline - now())) } catch { return true }
        if await isSettled() { return false }
    }
    return true
}
