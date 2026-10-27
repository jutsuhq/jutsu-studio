import AppKit
import JutsuAgent
import Presentation
import SwiftUI

/// The menu bar panel (ARCHITECTURE §6): the connection and the agents, today's agent budget, what waits for the
/// person, what runs, the last results, and Open, Settings and Quit. Each section is hidden while it has nothing to
/// show (`MenuBarPanel`). The panel is built only while it is open, once a second: closed, it shows what it showed as it
/// closed and reads none of the jobs, runs or agents, so their changes rebuild nothing.
struct MenuBarContent: View {
    @Environment(LiveJobs.self) private var liveJobs
    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @Environment(AgentService.self) private var agents
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppSettings.lowCreditThresholdKey) private var lowCreditThreshold =
        AppSettings.defaultLowCreditThreshold
    let system: SystemIntegration

    @State private var isOpen = false
    /// The panel as it closed.
    @State private var closedPanel: MenuBarPanel?
    @State private var budget: AgentCapabilities.Budget?

    var body: some View {
        content
            .frame(width: 330)
            .background {
                // The system makes the panel opaque under Reduce Transparency; this keeps it so on every macOS.
                if reducesTransparency { Rectangle().fill(.background).ignoresSafeArea() }
            }
            .background(PanelVisibility(isOpen: $isOpen).frame(width: 0, height: 0).accessibilityHidden(true))
            .onAppear {
                // Content made before the panel first opens is closed until it is seen.
                if !isOpen { closedPanel = makePanel(now: .now) }
            }
            .onChange(of: isOpen) { _, isOpen in
                // Read here, outside the body, so the closed panel observes nothing.
                closedPanel = isOpen ? nil : makePanel(now: .now)
            }
            .task(
                id: BudgetKey(
                    isOpen: isOpen, revision: isOpen ? liveJobs.stateRevision : 0, isAllowed: agents.isAllowed)
            ) {
                guard isOpen, agents.isAllowed else { return }
                budget = try? await agents.budgetToday()
            }
            .capturesOpenWindow(for: system)
    }

    @ViewBuilder private var content: some View {
        if let closedPanel {
            panel(closedPanel)
        } else {
            // Once a second, so elapsed times and estimates move between the engine's updates.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                panel(makePanel(now: context.date))
            }
        }
    }

    private func makePanel(now: Date) -> MenuBarPanel {
        MenuBarPanel(
            jobs: liveJobs.all, images: environment.imageSpend.charges, runs: runs, connection: connection.state,
            agents: agentsInput, now: now, times: liveJobs.generationTimes, lowCreditThreshold: lowCreditThreshold)
    }

    private func panel(_ panel: MenuBarPanel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MenuBarHeader(header: panel.header, isAllowed: allowedBinding) {
                environment.runOnAllJobs { engine in
                    switch panel.header.agents.control {
                    case .pause?: await engine.pauseAgentJobs()
                    case .resume?: await engine.resumeAgentJobs()
                    case nil: break
                    }
                }
            }
            if let today = panel.today { MenuBarTodaySection(today: today) }
            if !panel.needsYou.isEmpty {
                MenuBarNeedsYouSection(
                    items: panel.needsYou, overflow: panel.needsYouOverflow, open: open)
            }
            if !panel.running.isEmpty {
                MenuBarRunningSection(
                    items: panel.running, overflow: panel.runningOverflow, open: { system.showJob($0) },
                    cancel: cancel)
            }
            if !panel.recent.isEmpty {
                MenuBarRecentSection(items: panel.recent) { id in
                    environment.navigation.showInLibrary(id)
                    system.showMainWindow()
                }
            }
            if panel.isIdle {
                Text("Nothing running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            MenuBarFooter(system: system)
        }
        .padding(14)
    }

    private var runs: [MenuBarPanel.Run] {
        #if DEBUG
            if let runs = DebugLaunchHooks.panelRuns { return runs }
        #endif
        return environment.onDevice.runs.map(MenuBarPanel.Run.init)
            + environment.subtitles.runs.map(MenuBarPanel.Run.init)
    }

    private var agentsInput: MenuBarPanel.AgentsInput {
        var input = MenuBarPanel.AgentsInput(isAllowed: agents.isAllowed, activity: agents.activity, budget: budget)
        #if DEBUG
            DebugLaunchHooks.seedPanel(&input)
        #endif
        return input
    }

    private var allowedBinding: Binding<Bool> {
        Binding(get: { agents.isAllowed }, set: { agents.setAllowed($0) })
    }

    private var reducesTransparency: Bool {
        #if DEBUG
            if DebugLaunchHooks.reducesTransparency { return true }
        #endif
        return reduceTransparency
    }

    private func open(_ target: MenuBarPanel.AttentionTarget) {
        switch target {
        case .job(let id):
            system.showJob(id)
        case .sheet(let sheet, let item):
            guard let ask = agents.activity.asks.first(where: { $0.item == item && $0.sheet == sheet }) else { return }
            Task { await agents.openAsk(ask) }
        }
    }

    private func cancel(_ item: MenuBarPanel.Running) {
        switch item.kind {
        case .job:
            let kind = liveJobs.job(item.id)?.providerKind
            Task {
                if let message = await environment.perform(.cancel, on: item.id, kind: kind) {
                    environment.connection.alert = message
                }
            }
        case .onDevice: environment.onDevice.cancel(item.id)
        case .subtitles: environment.subtitles.cancel(item.id)
        }
    }

    private struct BudgetKey: Equatable {
        var isOpen: Bool
        var revision: Int
        var isAllowed: Bool
    }
}

/// The app, its connection and the agents: whether they are allowed, who sent requests lately, Pause agents.
private struct MenuBarHeader: View {
    let header: MenuBarPanel.Header
    @Binding var isAllowed: Bool
    let toggleAgentJobs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // The app icon carries the signature gradient: the panel's one brand moment.
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Jutsu Studio")
                        .font(.headline)
                    Text(connectionLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if let warning = header.plate?.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.warning)
            }
            PanelCard {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(header.agents.isAllowed ? .primary : .tertiary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Agents")
                            .font(.callout.weight(.medium))
                        Text(header.agents.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let control = header.agents.control {
                        Button(action: toggleAgentJobs) {
                            Text(control == .pause ? "Pause" : "Resume")
                        }
                        .panelButton()
                        .controlSize(.small)
                        .help(control == .pause ? "Pause the agents' jobs" : "Resume the agents' jobs")
                        .accessibilityLabel(control == .pause ? "Pause the agents' jobs" : "Resume the agents' jobs")
                    }
                    Toggle("Allow agents", isOn: $isAllowed)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("Allow agents")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    /// "Pro · 12,500 credits", "API key · Committed today: $4.20", "Not connected": one format each, so a
    /// translation can order its parts.
    private var connectionLine: String {
        guard let plate = header.plate else { return String(localized: "Not connected") }
        if plate.isAPIKey {
            guard let spend = header.spend else { return plate.badge }
            return String(
                localized: "\(plate.badge) · \(spend)",
                comment: "The menu bar panel's connection: the API key, then what is committed today.")
        }
        return String(
            localized: "\(plate.badge) · \(plate.amount) \(plate.unit)",
            comment: "The menu bar panel's connection: the plan, then the credits left and their unit.")
    }
}

/// Open Jutsu Studio, Settings… and Quit: the panel's few glass controls, in one container so they blend.
private struct MenuBarFooter: View {
    let system: SystemIntegration

    var body: some View {
        PanelGlassGroup {
            HStack(spacing: 8) {
                Button("Open Jutsu Studio") { system.showMainWindow() }
                    .panelButton(prominent: true)
                Spacer(minLength: 0)
                Button {
                    system.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .panelButton()
                .help("Settings…")
                .accessibilityLabel("Settings…")
                Button {
                    // Asks first while work runs, as ⌘Q does (`AppDelegate.applicationShouldTerminate`).
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .panelButton()
                .help("Quit Jutsu Studio")
                .accessibilityLabel("Quit Jutsu Studio")
            }
            .controlSize(.large)
        }
    }
}
