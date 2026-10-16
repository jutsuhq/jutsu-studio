import JutsuCore
import Persistence
import Presentation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What finished jobs cost per period, the CSV export and the daily cap of the connection.
struct SpendingSettingsView: View {
    let unit: Capabilities.CostUnit
    @Environment(AppEnvironment.self) private var environment
    @State private var period = SpendingPeriod.today
    @State private var export: CSVDocument?
    @State private var errorText = ""
    @State private var isShowingError = false
    /// Jobs finished in the longest period; `SpendingSummary` narrows them to the selected one.
    @Query private var records: [JobRecord]
    /// Decodes only records that changed since the last render.
    @State private var jobCache = DecodedJobCache<Job>()

    init(unit: Capabilities.CostUnit) {
        self.unit = unit
        let since = SpendingPeriod.month.start(now: .now)
        let unfinished = Date.distantPast
        _records = Query(
            filter: #Predicate<JobRecord> { $0.isTerminal == true && ($0.finishedAt ?? unfinished) >= since })
    }

    var body: some View {
        let jobs = jobCache.items(for: records, id: \.id, data: \.jobData) { try $0.job() }
        let summary = SpendingSummary(jobs, images: environment.imageSpend.charges, period: period, now: .now)
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            HStack {
                SegmentedControl(selection: $period, options: SpendingPeriod.allCases.map { ($0, $0.title) })
                    .fixedSize()
                Spacer()
                Button("Export CSV…") { Task { await exportCSV() } }
                    .buttonStyle(.secondaryAction)
            }
            SettingsSection(title: "Spent", footer: spentFooter) {
                SettingsRow(
                    label: "Charged", detail: SpendLine.jobsText(summary.chargedJobs), isFirst: true
                ) {
                    amount(summary.charged)
                }
                SettingsRow(
                    label: "Not charged",
                    detail: String(
                        localized: "Failed, rejected or canceled · \(SpendLine.jobsText(summary.notChargedJobs))")
                ) {
                    amount(summary.notCharged)
                }
            }
            breakdown(String(localized: "By mode"), summary.byMode)
            breakdown(String(localized: "By resolution"), summary.byResolution)
            breakdown(String(localized: "Draft or final"), summary.byKind)
            DailyCapSection(unit: unit)
            if unit == .credits {
                LowCreditSection()
                CreditHistorySection()
            }
        }
        .fileExporter(
            isPresented: Binding(isPresenting: $export), document: export,
            contentType: .commaSeparatedText, defaultFilename: SpendingCSV.defaultFileName(now: .now)
        ) { result in
            if case .failure(let error) = result { show(error) }
        }
        .alert("Can't export", isPresented: $isShowingError) {
            Button("OK") {}
        } message: {
            Text(errorText)
        }
    }

    private var spentFooter: String {
        unit == .credits
            ? String(
                localized: """
                    Estimates made before each job was submitted. Credit history below lists what the account was \
                    actually charged and refunded. USD is the API key balance, credits are the account plan.
                    """)
            : String(
                localized: """
                    Estimates made before each job was submitted. Higgsfield doesn't report the amount an API key \
                    was actually charged. USD is the API key balance, credits are the account plan.
                    """)
    }

    @ViewBuilder private func breakdown(_ title: String, _ lines: [SpendLine]) -> some View {
        if !lines.isEmpty {
            SettingsSection(title: title) {
                ForEach(lines) { line in
                    SettingsRow(label: line.title, detail: line.jobsText, isFirst: line.id == lines.first?.id) {
                        amount(line.total)
                    }
                }
            }
        }
    }

    private func amount(_ total: SpendTotal) -> some View {
        Text(total.text)
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Theme.muted)
            .textSelection(.enabled)
    }

    private func exportCSV() async {
        do {
            export = CSVDocument(text: try await environment.spendingCSV())
        } catch {
            show(error)
        }
    }

    private func show(_ error: any Error) {
        errorText = error.localizedDescription
        isShowingError = true
    }
}

/// The daily spend cap of the connection: USD for an API key, credits for an account.
private struct DailyCapSection: View {
    let unit: Capabilities.CostUnit
    @AppStorage(AppSettings.spendCapEnabledKey) private var isUSDCapEnabled = AppSettings.defaultSpendCapEnabled
    @AppStorage(AppSettings.spendCapUSDKey) private var capUSD = AppSettings.defaultSpendCapUSD
    @AppStorage(AppSettings.spendCapCreditsEnabledKey) private var isCreditCapEnabled =
        AppSettings.defaultSpendCapCreditsEnabled
    @AppStorage(AppSettings.spendCapCreditsKey) private var capCredits = AppSettings.defaultSpendCapCredits
    @Environment(AppEnvironment.self) private var environment
    @Environment(LiveJobs.self) private var liveJobs
    /// What the cap counts, as the engine and Create read it; `nil` until loaded.
    @State private var committedToday: Decimal?
    @State private var spendError: String?
    @State private var capText = ""
    @FocusState private var isCapFocused: Bool

    private var isCapEnabled: Binding<Bool> {
        unit == .usd ? $isUSDCapEnabled : $isCreditCapEnabled
    }

    private var footer: String {
        unit == .usd
            ? String(
                localized: """
                    A soft cap on the API balance: jobs over it ask for confirmation instead of starting. \
                    It counts jobs finished today and every job in the queue.
                    """)
            : String(
                localized: """
                    A soft cap on plan credits: jobs over it ask for confirmation instead of starting. \
                    It counts jobs finished today and every job in the queue.
                    """)
    }

    var body: some View {
        SettingsSection(title: "Daily cap", footer: footer) {
            SettingsRow(label: "Daily cap", isFirst: true) {
                Toggle("Daily cap", isOn: isCapEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(label: "Amount") {
                TextField("Amount", text: $capText)
                    .multilineTextAlignment(.trailing)
                    .focused($isCapFocused)
                    .themedField(isFocused: isCapFocused)
                    .frame(width: 110)
                    .onSubmit { commitCap() }
            }
            .disabled(!isCapEnabled.wrappedValue)
            .opacity(isCapEnabled.wrappedValue ? 1 : 0.45)
            SettingsRow(label: "Committed today", detail: spendError) {
                Text(
                    committedToday.map { AppSettings.formatSpend($0, unit: unit) }
                        ?? (spendError == nil ? "…" : String(localized: "Unavailable"))
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            }
        }
        .task(
            id: CommittedSpendKey(
                liveJobs.active + liveJobs.recentFinished(limit: .max), images: environment.imageSpend.charges,
                unit: unit)
        ) {
            await refreshCommitted()
        }
        .onAppear { capText = formattedCap }
        .onChange(of: isCapFocused) { _, isFocused in
            if !isFocused { commitCap() }
        }
        .onDisappear { commitCap() }
    }

    /// Reads the sum again whenever a job changes, and at midnight, when the new day starts from zero.
    private func refreshCommitted() async {
        while !Task.isCancelled {
            do {
                committedToday = try await environment.committedToday(in: unit)
                spendError = nil
            } catch {
                committedToday = nil
                spendError = error.localizedDescription
            }
            let wait = CommittedSpendKey.nextDay(after: .now).timeIntervalSinceNow
            do {
                try await Task.sleep(for: .seconds(max(wait, 1)))
            } catch {
                return
            }
        }
    }

    /// In en_US for dollars, the one form `parseCapAmount` reads back.
    private var formattedCap: String {
        unit == .usd
            ? AppSettings.formatUSD(capUSD, locale: Locale(identifier: "en_US")) : AppSettings.formatCredits(capCredits)
    }

    /// Keeps the last valid amount when the text doesn't parse.
    private func commitCap() {
        switch unit {
        case .usd:
            if let amount = AppSettings.parseCapAmount(capText) { capUSD = amount }
        case .credits:
            if let amount = AppSettings.parseCapCredits(capText) { capCredits = amount }
        }
        capText = formattedCap
    }
}

/// When the menu bar and the sidebar warn about low credits; accounts only, an API key's balance can't be read.
private struct LowCreditSection: View {
    @AppStorage(AppSettings.lowCreditThresholdKey) private var threshold = AppSettings.defaultLowCreditThreshold
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        SettingsSection(
            title: "Low credits",
            footer: String(localized: "The menu bar and the sidebar warn below this many credits.")
        ) {
            SettingsRow(label: "Warn below", isFirst: true) {
                TextField("Warn below", text: $text)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .themedField(isFocused: isFocused)
                    .frame(width: 110)
                    .onSubmit { commit() }
            }
        }
        .onAppear { text = AppSettings.formatCredits(threshold) }
        .onChange(of: isFocused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onDisappear { commit() }
    }

    /// Keeps the last valid amount when the text doesn't parse.
    private func commit() {
        if let amount = AppSettings.parseCapCredits(text) { threshold = amount }
        text = AppSettings.formatCredits(threshold)
    }
}

/// A CSV file for the save panel.
private struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// The account's credit movements as Higgsfield records them, newest first: what each generation was charged,
/// refunds of failed ones, and plan grants.
private struct CreditHistorySection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var feed: PagedFeed<CreditEntry>?
    /// Entries shown; "Show More" adds a step and loads the next page once the loaded ones run out.
    @State private var shown = Self.step

    private static let step = 10

    var body: some View {
        SettingsSection(
            title: "Credit history",
            footer: String(
                localized: "From Higgsfield, for every job on the account, including those made on higgsfield.ai.")
        ) {
            if let feed {
                rows(feed)
            }
        }
        .task(id: environment.history.owner) {
            shown = Self.step
            feed = environment.creditHistory.map { source in
                PagedFeed(failureTitle: String(localized: "Can't load the credit history")) { cursor in
                    let page = try await source.creditHistory(after: cursor)
                    return (page.items, page.nextCursor)
                }
            }
            await feed?.loadIfNeeded()
        }
    }

    @ViewBuilder private func rows(_ feed: PagedFeed<CreditEntry>) -> some View {
        let entries = feed.items.prefix(shown)
        ForEach(entries) { entry in
            SettingsRow(
                label: entry.title,
                detail: "\(entry.kindTitle) · \(entry.date.formatted(date: .abbreviated, time: .shortened))",
                isFirst: entry.id == entries.first?.id
            ) {
                Text(entry.amountText)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(entry.credits > 0 ? Theme.accent : Theme.muted)
                    .textSelection(.enabled)
            }
        }
        if let failure = feed.failure {
            SettingsRow(label: failure.title, detail: failure.message, isFirst: feed.items.isEmpty) {
                Button("Try Again") { Task { await feed.loadMore() } }
                    .buttonStyle(.secondaryAction)
            }
        } else if feed.isLoading {
            SettingsRow(label: "Loading…", isFirst: feed.items.isEmpty) {
                ProgressView().controlSize(.small)
            }
        } else if feed.items.count > shown || feed.hasMore {
            SettingsRow(label: "Older entries", isFirst: feed.items.isEmpty) {
                Button("Show More") { showMore(feed) }
                    .buttonStyle(.secondaryAction)
            }
        } else if feed.items.isEmpty {
            SettingsRow(label: "No credit movements yet", isFirst: true) { EmptyView() }
        }
    }

    private func showMore(_ feed: PagedFeed<CreditEntry>) {
        shown += Self.step
        guard feed.items.count < shown, feed.hasMore else { return }
        Task { await feed.loadMore() }
    }
}
