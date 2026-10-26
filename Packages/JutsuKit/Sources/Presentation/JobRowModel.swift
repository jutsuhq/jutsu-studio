import Foundation
import JutsuCore

/// What a Queue row shows for one job (FEATURES §4.3, prototype `jobRow`).
public struct JobRowModel: Sendable, Hashable, Identifiable {
    /// Semantic colors; the view maps them to the palette.
    public enum ColorRole: Sendable, Hashable {
        case accent
        case info
        case warning
        case danger
        case faint
    }

    public enum Action: Sendable, Hashable {
        /// Disabled once the API is processing the job; `help` is the tooltip either way.
        case cancel(isEnabled: Bool, help: String)
        /// Runs a job that was never charged again.
        case retry
        /// Fetches the paid result of a generation that finished but wasn't saved.
        case retryDownload
        /// Polls a job past its deadline again: Higgsfield may still finish it, and charge for it.
        case checkAgain
        /// Opens the inputs of a paid job in Create, where a new generation is charged again.
        case generateAgain
        case resume
        /// Moves a job waiting for a slot ahead of the other waiters.
        case runNext
        /// Resumes a job paused for its server price only after the user agrees to that price.
        case confirmPrice
        /// Rejected jobs: open the job's inputs in Create.
        case edit
        case showInFinder(URL)
        case openInLibrary
    }

    /// The steps a job goes through, shown as a stepper on active rows.
    public enum Stage: Int, Sendable, Hashable, CaseIterable {
        case prepare
        case upload
        case generate
        case save

        public var title: String {
            switch self {
            case .prepare: String(localized: "Prepare", bundle: .module)
            case .upload: String(localized: "Upload", bundle: .module)
            case .generate: String(localized: "Generate", bundle: .module)
            case .save: String(localized: "Save", bundle: .module)
            }
        }
    }

    /// The line under the meta: why a job stopped or was not charged.
    public struct Note: Sendable, Hashable {
        public var text: String
        public var role: ColorRole
    }

    /// How far a generating job is against the typical time of similar past jobs. An estimate, never a
    /// measured percentage: the API reports no progress while it generates.
    public struct TimeEstimate: Sendable, Hashable {
        /// "usually ~2 min", or "taking longer than usual" once past it.
        public var label: String
        /// Time since submit over the typical time, 0…1; stays at 1 once past it.
        public var fraction: Double
        public var isOverdue: Bool
        /// Says where the estimate comes from, for a tooltip.
        public var help: String
    }

    public var id: UUID
    /// Source file name and mode, e.g. "dance · Motion transfer".
    public var title: String
    public var mode: Mode
    public var isDraft: Bool
    /// "Motion transfer · 720p · 00:00.0–00:12.0 · $8.17 · 3 min ago".
    public var meta: String
    public var cost: String
    /// "Estimate" or "Price from Higgsfield", for `cost`.
    public var priceSource: String
    public var isCharged: Bool
    public var statusLabel: String
    public var statusRole: ColorRole
    /// What the status means, on hover; `nil` when the label says it all.
    public var statusHint: String?
    /// The status dot pulses while the engine works on the job.
    public var isWorking: Bool
    /// 0…1 for the states that report it, `nil` otherwise.
    public var progress: Double?
    /// "42%", next to the status label.
    public var progressText: String?
    public var note: Note?
    public var actions: [Action]
    /// The step the job is at; `nil` while paused and once it has finished.
    public var stage: Stage?
    /// Time since the job was queued or last retried, "1:05"; active jobs only.
    public var elapsed: String?
    /// Time since the API accepted the job, "0:42"; on the Generate step only.
    public var generating: String?
    /// While the API generates and enough similar jobs finished before; `nil` otherwise.
    public var timeEstimate: TimeEstimate?
    /// The prompt on one line; `nil` when there is none.
    public var prompt: String?
    /// "Agent · claude-code" for a job an AI agent queued; `nil` for the person's own.
    public var origin: String?
    /// "Allowed up to $2.00", the most the agent agreed to pay; `nil` for the person's own jobs.
    public var originDetail: String?

    /// - Parameters:
    ///   - now: for the relative time; finished jobs count from `finishedAt`.
    ///   - typical: how long similar past jobs took to generate, from `GenerationTimes`.
    public init(_ job: Job, now: Date, typical: GenerationTimes.Estimate? = nil) {
        let state = job.state
        id = job.id
        mode = job.spec.mode
        isDraft = job.spec.isDraft
        title = "\(job.spec.name) · \(job.spec.operation?.action.title ?? job.spec.mode.title)"
        isCharged = !Self.isNotCharged(job)
        cost = Self.costText(job, charged: isCharged)
        priceSource = job.priceSource
        let range = job.spec.source?.range
        meta = [
            job.spec.mode.title, job.spec.model == .genjutsu ? nil : job.spec.model.title, job.spec.resolutionTitle,
            range.map { "\(Self.timecode($0.lowerBound))–\(Self.timecode($0.upperBound))" }
                ?? CostText.limit(job.spec.duration),
            job.spec.variants > 1 ? String(localized: "\(job.spec.variants) variants", bundle: .module) : nil,
            cost,
            Self.relativeTime(from: job.finishedAt ?? job.attemptStartedAt, to: now),
        ].compactMap { $0 }.joined(separator: " · ")
        (statusLabel, statusRole) = Self.status(state)
        statusHint = Self.statusHint(state)
        isWorking = state.isActive && !state.isPaused
        if state.reportsProgress {
            let clamped = min(max(job.progress, 0), 1)
            progress = clamped
            progressText = CostText.percent(fraction: clamped)
        }
        note = Self.note(
            state, providerKind: job.providerKind, charged: isCharged, rejection: job.rejection,
            retrying: job.retrying, agentHold: job.agent?.hold)
        if note == nil, isWorking, let retrying = job.retrying { note = Self.retryNote(retrying, now: now) }
        if note == nil, let missing = job.missingVariants, missing > 0 { note = Self.missingVariantsNote(missing) }
        actions = Self.actions(job)
        stage = Self.stage(state)
        elapsed = state.isActive ? Self.duration(now.timeIntervalSince(job.attemptStartedAt)) : nil
        if stage == .generate, let submittedAt = job.submittedAt {
            generating = Self.duration(now.timeIntervalSince(submittedAt))
            if let typical {
                timeEstimate = Self.timeEstimate(elapsed: now.timeIntervalSince(submittedAt), typical: typical)
            }
        }
        let prompt = job.spec.prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        self.prompt = prompt.isEmpty ? nil : prompt
        if let agent = job.agent {
            origin = Self.originText(agent)
            let allowed = Self.moneyText(agent.maxCost)
            originDetail = String(localized: "Allowed up to \(allowed)", bundle: .module)
        }
    }

    /// "Agent · claude-code", or "Agent" when the client gave no name.
    static func originText(_ agent: AgentOrigin) -> String {
        guard let client = agent.client, !client.isEmpty else { return String(localized: "Agent", bundle: .module) }
        return String(localized: "Agent · \(client)", bundle: .module)
    }

    /// "$2.00" or "40 cr".
    static func moneyText(_ money: AgentMoney) -> String {
        switch money.unit {
        case .usdCents: CostText.dollars(Decimal(money.amount) / 100)
        case .credits: CostText.credits(Decimal(money.amount))
        }
    }

    // MARK: Rules

    /// The submit's answer started fewer variants than it asked for; the ones it started are tracked as usual.
    static func missingVariantsNote(_ missing: Int) -> Note {
        Note(
            text: String(
                localized: "Higgsfield started fewer variants than asked for: \(missing) missing", bundle: .module),
            role: .warning)
    }

    /// A job the API finished is charged even when its download then failed or was canceled.
    static func isNotCharged(_ job: Job) -> Bool {
        job.state.isTerminal && !job.isCharged
    }

    static func status(_ state: JobState) -> (String, ColorRole) {
        switch state {
        case .preparing: (String(localized: "Preparing", bundle: .module), .accent)
        case .uploading: (String(localized: "Uploading", bundle: .module), .accent)
        case .waitingForSlot: (String(localized: "Waiting for slot", bundle: .module), .info)
        case .queued: (String(localized: "Queued", bundle: .module), .info)
        case .processing: (String(localized: "Processing", bundle: .module), .accent)
        case .downloading: (String(localized: "Downloading", bundle: .module), .accent)
        case .paused: (String(localized: "Paused", bundle: .module), .warning)
        case .done: (String(localized: "Done", bundle: .module), .accent)
        case .failed: (String(localized: "Failed", bundle: .module), .danger)
        case .rejected: (String(localized: "Rejected", bundle: .module), .warning)
        case .canceled: (String(localized: "Canceled", bundle: .module), .faint)
        }
    }

    static func statusHint(_ state: JobState) -> String? {
        guard state == .waitingForSlot else { return nil }
        return String(localized: "Sent once a slot is free", bundle: .module)
    }

    static func stage(_ state: JobState) -> Stage? {
        switch state {
        case .preparing: .prepare
        case .uploading, .waitingForSlot: .upload
        case .queued, .processing: .generate
        case .downloading: .save
        default: nil
        }
    }

    static func actions(_ job: Job) -> [Action] {
        switch job.state {
        case .done:
            return (job.outputFile.map { [.showInFinder($0)] } ?? []) + [.openInLibrary]
        case .failed where job.mayStillFinish:
            return [.checkAgain]
        case .failed, .canceled:
            return job.hasPaidOutput ? [.retryDownload, .generateAgain] : [.retry]
        case .rejected:
            return [.edit]
        case .paused(.priceAboveCap), .paused(.agentLimit):
            return [.confirmPrice, cancel(job.state)]
        case .paused:
            return [.resume, cancel(job.state)]
        case .waitingForSlot where job.submitAttempt == nil:
            return [.runNext, cancel(job.state)]
        default:
            return [cancel(job.state)]
        }
    }

    /// `nil` for a typical time of zero, which no bar can be filled against.
    static func timeEstimate(elapsed: TimeInterval, typical: GenerationTimes.Estimate) -> TimeEstimate? {
        guard typical.total > 0 else { return nil }
        let isOverdue = elapsed > typical.total
        return TimeEstimate(
            label: isOverdue
                ? String(localized: "taking longer than usual", bundle: .module)
                : String(localized: "usually \(approximate(typical.total))", bundle: .module),
            fraction: min(max(elapsed / typical.total, 0), 1), isOverdue: isOverdue,
            help: String(localized: "Estimate from \(typical.sampleCount) past jobs", bundle: .module))
    }

    private static func cancel(_ state: JobState) -> Action {
        if state == .downloading || state == .paused(.notEnoughDiskSpace) {
            return .cancel(isEnabled: true, help: String(localized: "Stop download", bundle: .module))
        }
        if state.isCancellable {
            return .cancel(isEnabled: true, help: String(localized: "Cancel job", bundle: .module))
        }
        return .cancel(isEnabled: false, help: String(localized: "Can't cancel while processing", bundle: .module))
    }
}

extension JobState {
    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    /// The states whose `Job.progress` means something. Not `processing`: the API reports no progress
    /// while it generates, so the row would sit at 0% until the download starts.
    var reportsProgress: Bool {
        switch self {
        case .preparing, .uploading, .downloading: true
        default: false
        }
    }
}

extension JobRowModel {
    /// The finished result's video, which the row drags out; `nil` until there is one.
    public var file: URL? {
        actions.lazy.compactMap { action in
            if case .showInFinder(let url) = action { url } else { nil }
        }.first
    }
}
