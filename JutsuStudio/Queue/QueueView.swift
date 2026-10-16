import AppKit
import JobEngine
import JutsuCore
import Persistence
import Presentation
import SwiftData
import SwiftUI

/// Active jobs, jobs that didn't finish and recent results, with their actions (prototype `#queue`). Rows come
/// from `LiveJobs`, which the engine keeps current, and from the store for jobs that didn't finish; the rules for
/// labels and actions live in `JobRowModel`.
struct QueueView: View {
    static let finishedLimit = 8

    @Environment(LiveJobs.self) private var liveJobs
    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var navigation
    @Environment(ConnectionStore.self) private var connection
    /// `nil` until set in Settings; the connection's default applies then.
    @AppStorage(AppSettings.maxConcurrencyKey) private var storedConcurrency: Int?
    @AppStorage(AppSettings.queueProblemsClearedAtKey) private var problemsClearedAt = 0.0
    @State private var duplicateRequest: JobSpec?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                header
                SectionLabel(title: "Active", detail: "\(liveJobs.activeCount)")
                // Generate… requests are listed below the jobs, so either keeps the queue from being empty.
                if liveJobs.active.isEmpty && environment.referenceGenerator.runs.isEmpty {
                    EmptyState(
                        systemImage: "square.stack.3d.up", title: "Nothing running",
                        detail: String(
                            localized: "Start a draft from Create. Jobs keep running when the window is closed.")
                    ) {
                        Button("Go to Create") { navigation.selection = .create }
                            .buttonStyle(.secondaryAction)
                    }
                    .card()
                }
                QueueEntryList(entries: liveJobs.activeEntries, duplicate: duplicate)
                ImageRequestsSection()
                ProblemsSection(
                    clearedAt: QueueProblems(clearedAt: problemsClearedAt, removed: "").clearedAt,
                    duplicate: duplicate)
                let finished = liveJobs.recentFinishedEntries(limit: Self.finishedLimit)
                SectionLabel(title: "Finished", detail: "\(finished.count)")
                    .padding(.top, 18)
                if finished.isEmpty {
                    Text("Finished jobs appear here and in the Library.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.faint)
                        .padding(.vertical, Theme.Spacing.small)
                }
                QueueEntryList(entries: finished, duplicate: duplicate)
            }
            .pagePadding()
        }
        .background(Theme.background)
        .navigationTitle("Queue")
        .duplicating($duplicateRequest)
    }

    /// Hands the job to `duplicating`, which drops a click that comes while another duplicate is being queued.
    private func duplicate(_ job: Job) -> (() -> Void)? {
        { duplicateRequest = job.spec }
    }

    private var header: some View {
        PageHeader(
            title: "Queue",
            subtitle: String(localized: "Jobs keep running in the background and resume after restart.")
        ) {
            HStack(spacing: Theme.Spacing.small) {
                Pill(
                    text: liveJobs.slotsSummary(
                        limit: AppSettings.maxConcurrency(stored: storedConcurrency, for: connection.state.kind)),
                    dot: Theme.accent,
                    isPulsing: liveJobs.busySlots > 0)
                QueueControls()
                    .buttonStyle(.iconAction)
                Button {
                    navigation.selection = .create
                } label: {
                    Label("New job", systemImage: "plus")
                }
                .buttonStyle(.secondaryAction)
            }
        }
    }
}

/// Jobs on their own, and batches as a header over their jobs.
private struct QueueEntryList: View {
    let entries: [QueueEntry]
    /// The Duplicate action of a job; `nil` while a duplicate is being queued.
    let duplicate: (Job) -> (() -> Void)?
    /// Hides a job from the Queue; `nil` where rows can't be removed.
    var remove: ((Job) -> Void)?

    var body: some View {
        ForEach(entries) { entry in
            switch entry {
            case .job(let job):
                row(job)
            case .batch(let batch):
                BatchHeader(batch: batch)
                ForEach(batch.jobs) { job in
                    row(job)
                        .padding(.leading, Theme.Spacing.large)
                }
            }
        }
    }

    private func row(_ job: Job) -> some View {
        JobRow(job: job, duplicate: duplicate(job), remove: remove.map { remove in { remove(job) } })
    }
}

/// Failed, rejected and canceled jobs, read from the store so newer results never push them out of reach and
/// they come back after a relaunch, until the user removes them (`QueueProblems`).
private struct ProblemsSection: View {
    let duplicate: (Job) -> (() -> Void)?

    @Query private var records: [JobRecord]
    @Environment(LiveJobs.self) private var liveJobs
    @AppStorage(AppSettings.queueProblemsClearedAtKey) private var clearedAt = 0.0
    @AppStorage(AppSettings.queueRemovedProblemsKey) private var removed = ""
    @State private var cache = DecodedJobCache<Job>()
    @State private var isConfirmingClear = false

    /// - Parameter clearedAt: jobs finished until then were cleared, so they aren't fetched.
    init(clearedAt: Date?, duplicate: @escaping (Job) -> (() -> Void)?) {
        _records = Query(JobRecord.problemsNewestFirst(finishedAfter: clearedAt, limit: QueueProblems.storedLimit))
        self.duplicate = duplicate
    }

    var body: some View {
        let problems = QueueProblems(clearedAt: clearedAt, removed: removed)
        let stored = cache.items(for: records, id: \.id, data: \.jobData) { try $0.job() }
        let entries = liveJobs.problemEntries(stored: stored, problems: problems)
        if !entries.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                SectionLabel(
                    title: "Didn't finish", detail: "\(entries.reduce(0) { $0 + $1.jobs.count })")
                Button("Clear all") { isConfirmingClear = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .semibold))
                    .hoverHint(String(localized: "Remove all from Queue"))
            }
            .padding(.top, 18)
            .confirmationDialog("Clear the jobs that didn't finish?", isPresented: $isConfirmingClear) {
                Button("Clear all", role: .destructive) {
                    var next = problems
                    next.clearAll()
                    save(next)
                }
            } message: {
                Text("They leave the Queue. What they cost still counts in today's spending.")
            }
            QueueEntryList(entries: entries, duplicate: duplicate) { job in
                var next = problems
                next.remove(job.id, loaded: records.map(\.id))
                save(next)
            }
        }
    }

    private func save(_ problems: QueueProblems) {
        clearedAt = problems.storedClearedAt
        removed = problems.storedRemoved
    }
}

private struct JobRow: View {
    let job: Job
    /// `nil` while a duplicate is being queued.
    let duplicate: (() -> Void)?
    /// Hides the job from the Queue; `nil` where rows can't be removed.
    let remove: (() -> Void)?

    @Environment(LiveJobs.self) private var liveJobs

    var body: some View {
        let typical = liveJobs.generationTimes.estimate(for: job.spec)
        // Every second while the job runs, for its elapsed timer; otherwise for "3 min ago".
        TimelineView(.periodic(from: .now, by: job.state.isActive ? 1 : 30)) { context in
            JobRowContent(
                job: job, model: JobRowModel(job, now: context.date, typical: typical), duplicate: duplicate,
                remove: remove)
        }
    }
}

private struct JobRowContent: View {
    let job: Job
    let model: JobRowModel
    /// `nil` while a duplicate is being queued.
    let duplicate: (() -> Void)?
    /// Hides the job from the Queue; `nil` where rows can't be removed.
    let remove: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @Environment(NavigationModel.self) private var navigation
    @State private var isBusy = false

    private var isSelected: Bool { navigation.queueSelection == job.id }

    var body: some View {
        let isActive = job.state.isActive
        HStack(alignment: .center, spacing: Theme.Spacing.large) {
            JobPreview(job: job, height: isActive ? 116 : 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.system(size: isActive ? 14 : 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(model.meta)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .hoverHint("\(model.priceSource): \(model.cost)")
                if isActive, let prompt = model.prompt {
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .hoverHint(job.spec.prompt)
                }
                if let note = model.note {
                    Text(note.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(note.role.color)
                        .lineLimit(2)
                } else if let stage = model.stage {
                    StageStepper(
                        stage: stage,
                        detail: [model.progressText, model.generating].compactMap { $0 }.joined(separator: " · ")
                    )
                    .padding(.top, 6)
                    if let progress = model.progress {
                        RenderProgress(value: progress)
                            .frame(maxWidth: 420)
                            .padding(.top, 2)
                    } else if let estimate = model.timeEstimate {
                        EstimatedProgress(estimate: estimate)
                            .frame(maxWidth: 420)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
                if let hint = model.statusHint {
                    Pill(status: model.statusLabel, role: model.statusRole, isPulsing: model.isWorking)
                        .hoverHint(hint)
                } else {
                    Pill(status: model.statusLabel, role: model.statusRole, isPulsing: model.isWorking)
                }
                if let elapsed = model.elapsed {
                    Label(elapsed, systemImage: "timer")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                        .hoverHint(String(localized: "Time since queued or retried"))
                }
                HStack(spacing: 6) {
                    ForEach(model.actions, id: \.self) { action in
                        button(for: action)
                    }
                    if let ids = SupportIDs.line(for: job) {
                        Button {
                            NSPasteboard.general.copyText(ids)
                        } label: {
                            Label("Copy IDs", systemImage: "number")
                        }
                        .hoverHint(String(localized: "Copy job IDs"))
                    }
                    Button {
                        duplicate?()
                    } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .disabled(duplicate == nil)
                    .hoverHint(String(localized: "Duplicate job"))
                    .accessibilityLabel("Duplicate")
                    if let remove {
                        Button(action: remove) {
                            Image(systemName: "xmark")
                        }
                        .hoverHint(String(localized: "Remove from Queue"))
                        .accessibilityLabel("Remove")
                    }
                }
                .buttonStyle(.secondaryAction)
                .disabled(isBusy)
            }
            .fixedSize()
        }
        .padding(Theme.Spacing.medium)
        .card(isHighlighted: isSelected)
        // A click on the row, outside its buttons, selects it for the Queue menu's Cancel Job and Retry.
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { navigation.queueSelection = isSelected ? nil : job.id }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background {
            if isSelected { Color.clear.focusedSceneValue(\.queueCommands, menuCommands) }
        }
        .freshGlow(isFreshlyDone)
        .resultFileDrag(model.file.map { ResultFile(id: job.id, url: $0) })
    }

    /// The Queue menu's job items for this row, by the rules of its buttons; none while a command runs.
    private var menuCommands: QueueCommands {
        guard !isBusy else { return QueueCommands() }
        let commands = QueueJobCommands(model)
        var menu = QueueCommands()
        if commands.canCancel { menu.cancel = { perform(.cancel) } }
        if let retry = commands.retry {
            menu.retry = MenuCommand(title: commands.retryTitle) { perform(retry) }
        }
        return menu
    }

    /// Glows once when the row first shows a job that finished a moment ago.
    private var isFreshlyDone: Bool {
        guard job.state == .done, let finishedAt = job.finishedAt else { return false }
        return Date.now.timeIntervalSince(finishedAt) < 10
    }

    @ViewBuilder
    private func button(for action: JobRowModel.Action) -> some View {
        switch action {
        case .cancel(let isEnabled, let help):
            Button("Cancel") { perform(.cancel) }
                .disabled(!isEnabled)
                .hoverHint(help)
        case .retry:
            Button("Retry", systemImage: "arrow.clockwise") { perform(.retry) }
                .hoverHint(String(localized: "Retry"))
        case .retryDownload:
            Button("Retry download", systemImage: "arrow.down.circle") { perform(.retry) }
                .hoverHint(String(localized: "Retry download"))
        case .checkAgain:
            Button("Check again", systemImage: "arrow.clockwise") { perform(.checkAgain) }
                .hoverHint(String(localized: "Check again"))
        case .generateAgain:
            editButton(
                "Generate again", systemImage: "arrow.triangle.2.circlepath",
                help: String(localized: "Open in Create"))
        case .resume:
            Button("Resume", systemImage: "play.fill") { perform(.resume) }
                .hoverHint(String(localized: "Resume"))
        case .runNext:
            Button("Run next", systemImage: "arrow.up.to.line") { perform(.runNext) }
                .hoverHint(String(localized: "Run next"))
        case .confirmPrice:
            ConfirmPriceButton(price: model.cost) { perform(.resume) }
        case .edit:
            editButton("Edit", systemImage: "pencil", help: String(localized: "Open in Create"))
        case .showInFinder(let url):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .hoverHint(String(localized: "Show in Finder"))
            .accessibilityLabel("Show in Finder")
        case .openInLibrary:
            Button {
                navigation.showInLibrary(job.id)
            } label: {
                Image(systemName: "arrow.right")
            }
            .hoverHint(String(localized: "Open in Library"))
            .accessibilityLabel("Open in Library")
        }
    }

    private func editButton(_ title: String, systemImage: String, help: String) -> some View {
        Button {
            navigation.edit(job.spec)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .hoverHint(help)
    }

    private func perform(_ command: JobCommand) {
        let (environment, id, kind) = (environment, job.id, job.providerKind)
        isBusy = true
        Task {
            defer { isBusy = false }
            if let message = await environment.perform(command, on: id, kind: kind) { connection.alert = message }
        }
    }
}

/// Resumes a job paused for its server price, after the user agrees to that price.
private struct ConfirmPriceButton: View {
    let price: String
    let resume: () -> Void

    @State private var isConfirming = false

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            Label("Review price", systemImage: "play.fill")
        }
        .hoverHint("Price above estimate")
        .confirmationDialog("Start this job for \(price)?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Start for \(price)", action: resume)
            Button("Not now", role: .cancel) {}
        } message: {
            Text("This is the price from Higgsfield for the uploaded files. It takes today's spending over your cap.")
        }
    }
}
