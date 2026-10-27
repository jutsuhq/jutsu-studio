import Foundation
import JutsuAgent
import JutsuCore

/// What the menu bar panel shows (ARCHITECTURE §6, The menu bar panel): the connection and the agents, today's agent
/// budget, what waits for the person, what runs, and the last results. The view hides each section that is empty.
public struct MenuBarPanel: Sendable, Hashable {
    /// More rows than these make the panel taller than a laptop screen.
    public static let runningLimit = 4
    public static let needsYouLimit = 3
    public static let recentLimit = 3

    public struct Header: Sendable, Hashable {
        /// The plan and its credits, or the API key; `nil` while nothing is connected.
        public var plate: AccountPlate?
        /// "Committed today: $12.40" with an API key, whose balance can't be read.
        public var spend: String?
        public var agents: Agents
    }

    public enum AgentsControl: Sendable, Hashable {
        /// Pauses the agents' jobs not yet sent (`JobEngine.pauseAgentJobs`).
        case pause
        case resume
    }

    public struct Agents: Sendable, Hashable {
        /// Settings › Agents › Allow agents.
        public var isAllowed: Bool
        /// "No agent connected", "claude-code connected", "2 agents connected"; "Agents off".
        public var status: String
        /// `nil` while the agents have no job to pause or resume.
        public var control: AgentsControl?
    }

    /// Today's agent budget, with a bar of what is spent and reserved.
    public struct Today: Sendable, Hashable {
        /// "$4.20 spent".
        public var spent: String
        /// "of $10.00", the daily agent budget; `nil` while none is set.
        public var limit: String?
        /// "$1.00 reserved", for submits sent and not answered yet; `nil` when nothing is.
        public var reserved: String?
        /// "$4.80 left", or that no budget is set.
        public var remaining: String
        public var spentFraction: Double
        public var reservedFraction: Double
        /// Nothing is left: agents' paid requests wait for the person.
        public var isUsedUp: Bool
        /// "Daily cap: $12.00 of $50.00", the person's own cap, which counts every job.
        public var cap: String?
    }

    /// Where a Needs you row opens.
    public enum AttentionTarget: Sendable, Hashable {
        /// The job's row in the Queue.
        case job(UUID)
        /// The item's sheet over the Library.
        case sheet(AgentSheet, item: UUID)
    }

    /// Something only the person can settle: a held job, or an agent's request for a model download.
    public struct Attention: Sendable, Hashable, Identifiable {
        public var title: String
        public var reason: String
        public var target: AttentionTarget

        /// A job, or an item's sheet: an item can wait in two sheets.
        public var id: AttentionTarget { target }
    }

    public enum RunKind: Sendable, Hashable {
        case job
        case onDevice
        case subtitles
    }

    /// A paid job or a run on this Mac.
    public struct Running: Sendable, Hashable, Identifiable {
        public var id: UUID
        public var kind: RunKind
        public var title: String
        /// "Generating · 40%", "Upscale 4× · 12%".
        public var detail: String
        /// Reported progress, 0…1.
        public var progress: Double?
        /// A generating job against the typical time, when no progress is reported.
        public var estimate: JobRowModel.TimeEstimate?
        /// `nil` when it can't be canceled at all; disabled once the API processes a job.
        public var cancel: Cancel?
    }

    public struct Cancel: Sendable, Hashable {
        public var isEnabled: Bool
        public var help: String
    }

    /// A finished result.
    public struct Recent: Sendable, Hashable, Identifiable {
        /// The job's ID, which Library opens.
        public var id: UUID
        public var title: String
        /// "3 min ago".
        public var detail: String
        public var file: URL?
    }

    /// A run on this Mac, as the panel lists it: Enhance's (`OnDeviceRuns`) or subtitles' (`SubtitleRuns`).
    public struct Run: Sendable, Hashable {
        public var id: UUID
        public var kind: RunKind
        public var title: String
        public var detail: String
        public var fraction: Double?

        public init(id: UUID, kind: RunKind, title: String, detail: String, fraction: Double?) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.fraction = fraction
        }

        public init(_ run: OnDeviceRuns.Run) {
            self.init(
                id: run.id, kind: .onDevice, title: run.request.file.deletingPathExtension().lastPathComponent,
                detail: OnDeviceText.progress(of: run), fraction: run.state.fraction)
        }

        public init(_ run: SubtitleRuns.Run) {
            self.init(
                id: run.id, kind: .subtitles, title: run.request.file.deletingPathExtension().lastPathComponent,
                detail: SubtitleText.progress(of: run), fraction: run.state.fraction)
        }
    }

    /// The agents' side, from the app's `AgentService`.
    public struct AgentsInput: Sendable, Equatable {
        public var isAllowed: Bool
        public var activity: AgentActivity
        /// Today's budget as `capabilities` reports it; `nil` while nothing is connected or before it is read.
        public var budget: AgentCapabilities.Budget?

        public init(isAllowed: Bool, activity: AgentActivity = AgentActivity(), budget: AgentCapabilities.Budget? = nil)
        {
            self.isAllowed = isAllowed
            self.activity = activity
            self.budget = budget
        }
    }

    public var header: Header
    public var today: Today?
    public var needsYou: [Attention]
    /// "and 2 more", past `needsYouLimit`.
    public var needsYouOverflow: String?
    public var running: [Running]
    /// "and 2 more", past `runningLimit`.
    public var runningOverflow: String?
    public var recent: [Recent]

    /// Nothing waits, runs or finished lately.
    public var isIdle: Bool { needsYou.isEmpty && running.isEmpty && recent.isEmpty }

    /// - Parameters:
    ///   - jobs: every job the app knows, finished ones included for today's spend and the recent results.
    ///   - images: the reference image requests, which count toward today's spend too.
    ///   - runs: the runs on this Mac waiting or running, in the order they run.
    ///   - times: for the time estimate of generating jobs.
    public init(
        jobs: [Job], images: [ImageCharge] = [], runs: [Run] = [], connection: ConnectionState, agents: AgentsInput,
        now: Date, times: GenerationTimes = GenerationTimes(), lowCreditThreshold: Int = 0,
        calendar: Calendar = .current, locale: Locale = .current
    ) {
        let active = jobs.filter(\.state.isActive).sorted { $0.createdAt < $1.createdAt }
        today = agents.isAllowed ? agents.budget.flatMap(Self.today) : nil
        // Today's cap line already counts every job, so the header doesn't repeat it.
        header = Header(
            plate: AccountPlate(connection: connection, lowCreditThreshold: lowCreditThreshold, locale: locale),
            spend: today?.cap != nil
                ? nil : Self.spend(jobs, images: images, connection: connection, now: now, calendar: calendar),
            agents: Self.agents(agents, jobs: active, now: now))

        let rows = active.map { JobRowModel($0, now: now, typical: times.estimate(for: $0.spec)) }
        let held = zip(active, rows).filter { Self.needsPerson($0.0) }.map { Self.attention($0.1) }
        let asks = agents.activity.openAsks(at: now).map(Self.attention)
        let waiting = asks + held
        needsYou = Array(waiting.prefix(Self.needsYouLimit))
        needsYouOverflow = Self.overflow(waiting.count, limit: Self.needsYouLimit)

        let work =
            zip(active, rows).filter { !Self.needsPerson($0.0) }.map { Self.running($0.1) } + runs.map(Self.running)
        running = Array(work.prefix(Self.runningLimit))
        runningOverflow = Self.overflow(work.count, limit: Self.runningLimit)

        recent = jobs.filter { $0.state == .done }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            .prefix(Self.recentLimit)
            .map { job in
                Recent(
                    id: job.id, title: JobRowModel(job, now: now).title,
                    detail: JobRowModel.relativeTime(from: job.finishedAt ?? job.createdAt, to: now),
                    file: job.outputFile)
            }
    }

    // MARK: The status item

    /// What VoiceOver reads for the status item: "Jutsu Studio, 2 active jobs".
    public static func accessibilityLabel(activeCount: Int) -> String {
        switch activeCount {
        case ...0: String(localized: "Jutsu Studio, no active jobs", bundle: .module)
        case let count: String(localized: "Jutsu Studio, \(count) active jobs", bundle: .module)
        }
    }

    /// The number next to the status item icon; `nil` when the setting is off or nothing runs.
    public static func countText(activeCount: Int, isShown: Bool) -> String? {
        isShown && activeCount > 0 ? String(activeCount) : nil
    }

    /// How many steps the status item's progress bar has: each step is a new image, so the icon is redrawn a dozen
    /// times over a job, not at every progress report.
    public static let iconSteps = 12

    /// How far the running work is, together, in `iconSteps` steps for the status item; `nil` when nothing runs.
    /// Work that reports no progress yet counts as not started.
    public static func iconProgress(_ running: [Running]) -> Double? {
        guard !running.isEmpty else { return nil }
        let total = running.reduce(0) { $0 + min(max($1.progress ?? $1.estimate?.fraction ?? 0, 0), 1) }
        let steps = Double(iconSteps)
        return (total / Double(running.count) * steps).rounded(.down) / steps
    }

    /// How far all the work is, for the status item: every paid job not held for the person, and every run.
    public static func iconProgress(
        jobs: [Job], runs: [Run], now: Date, times: GenerationTimes = GenerationTimes()
    ) -> Double? {
        let work =
            jobs.filter { $0.state.isActive && !needsPerson($0) }
            .map { running(JobRowModel($0, now: now, typical: times.estimate(for: $0.spec))) } + runs.map(running)
        return iconProgress(work)
    }

    // MARK: Sections

    static func spend(
        _ jobs: [Job], images: [ImageCharge], connection: ConnectionState, now: Date, calendar: Calendar
    ) -> String? {
        guard case .apiKey = connection else { return nil }
        let committed = DailySpend.committed(jobs, images: images, on: now, calendar: calendar)
        return String(localized: "Committed today: \(AppSettings.formatUSD(committed))", bundle: .module)
    }

    static func agents(_ input: AgentsInput, jobs: [Job], now: Date) -> Agents {
        guard input.isAllowed else {
            return Agents(isAllowed: false, status: String(localized: "Agents off", bundle: .module), control: nil)
        }
        let clients = input.activity.connectedClients(at: now)
        let status =
            switch clients.count {
            case 0: String(localized: "No agent connected", bundle: .module)
            case 1: String(localized: "\(clients[0]) connected", bundle: .module)
            case let count: String(localized: "\(count) agents connected", bundle: .module)
            }
        let agentJobs = jobs.filter { $0.agent != nil }
        let control: AgentsControl? =
            if agentJobs.contains(where: { $0.state.isPausableByUser && $0.submitAttempt == nil }) {
                .pause
            } else if agentJobs.contains(where: { $0.state == .paused(.byUser) }) {
                .resume
            } else {
                nil
            }
        return Agents(isAllowed: true, status: status, control: control)
    }

    static func today(_ budget: AgentCapabilities.Budget) -> Today? {
        guard budget.dailyLimit > 0 || budget.dailyCap != nil else { return nil }
        let money = { (amount: Int) in JobRowModel.moneyText(AgentMoney(amount, AgentMoney.Unit(budget.unit))) }
        let limit = Double(max(budget.dailyLimit, 1))
        let spent = Double(budget.spentToday)
        let cap = budget.dailyCap.map { cap in
            String(localized: "Your daily cap: \(money(budget.capTakenToday ?? 0)) of \(money(cap))", bundle: .module)
        }
        return Today(
            spent: String(localized: "\(money(budget.spentToday)) spent", bundle: .module),
            limit: budget.dailyLimit > 0 ? String(localized: "of \(money(budget.dailyLimit))", bundle: .module) : nil,
            reserved: budget.reservedToday > 0
                ? String(localized: "\(money(budget.reservedToday)) reserved", bundle: .module) : nil,
            remaining: budget.dailyLimit > 0
                ? String(localized: "\(money(budget.remaining)) left", bundle: .module)
                : String(localized: "No agent budget set", bundle: .module),
            spentFraction: min(spent / limit, 1),
            reservedFraction: min(Double(budget.reservedToday) / limit, max(0, 1 - spent / limit)),
            isUsedUp: budget.dailyLimit > 0 && budget.remaining == 0, cap: cap)
    }

    /// Held for the person: every pause but their own Pause all (`AgentJob.needsPerson`).
    static func needsPerson(_ job: Job) -> Bool {
        if case .paused(let reason) = job.state { reason != .byUser } else { false }
    }

    static func attention(_ row: JobRowModel) -> Attention {
        Attention(
            title: row.title, reason: row.note?.text ?? row.statusHint ?? row.statusLabel,
            target: .job(row.id))
    }

    static func attention(_ ask: AgentActivity.Ask) -> Attention {
        let reason =
            switch ask.sheet {
            case .upscaleOnMac: String(localized: "An agent asks to download the upscale model", bundle: .module)
            case .subtitles: String(localized: "An agent asks to download a speech model", bundle: .module)
            }
        return Attention(title: ask.title, reason: reason, target: .sheet(ask.sheet, item: ask.item))
    }

    static func running(_ row: JobRowModel) -> Running {
        var cancel: Cancel?
        for case .cancel(let isEnabled, let help) in row.actions { cancel = Cancel(isEnabled: isEnabled, help: help) }
        let detail = row.progressText.map { "\(row.statusLabel) · \($0)" } ?? row.statusLabel
        return Running(
            id: row.id, kind: .job, title: row.title, detail: detail, progress: row.progress,
            estimate: row.progress == nil ? row.timeEstimate : nil, cancel: cancel)
    }

    static func running(_ run: Run) -> Running {
        Running(
            id: run.id, kind: run.kind, title: run.title, detail: run.detail, progress: run.fraction, estimate: nil,
            cancel: Cancel(isEnabled: true, help: String(localized: "Cancel", bundle: .module)))
    }

    static func overflow(_ count: Int, limit: Int) -> String? {
        count > limit ? String(localized: "and \(count - limit) more", bundle: .module) : nil
    }
}
