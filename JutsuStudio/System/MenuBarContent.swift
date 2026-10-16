import AppKit
import Presentation
import SwiftUI

/// The menu bar panel: active jobs with progress, today's spend or credits, open and quit. A job's row opens it in
/// the Queue.
struct MenuBarContent: View {
    @Environment(LiveJobs.self) private var liveJobs
    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @AppStorage(AppSettings.lowCreditThresholdKey) private var lowCreditThreshold =
        AppSettings.defaultLowCreditThreshold
    let system: SystemIntegration

    var body: some View {
        // Every second, so elapsed times and estimates move between the engine's updates.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            panel(now: context.date)
        }
        .padding(12)
        .frame(width: 300)
        .capturesOpenWindow(for: system)
    }

    private func panel(now: Date) -> some View {
        let summary = MenuBarSummary(
            jobs: liveJobs.active + liveJobs.recentFinished(limit: .max), images: environment.imageSpend.charges,
            connection: connection.state, now: now, times: liveJobs.generationTimes)
        return VStack(alignment: .leading, spacing: 10) {
            Text(summary.headline)
                .font(.headline)
            ForEach(summary.rows) { row in
                Button {
                    system.showJob(row.id)
                } label: {
                    MenuBarJobRow(row: row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show in the Queue")
            }
            if let overflow = summary.overflow {
                Text(overflow)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            if liveJobs.canPauseAll || liveJobs.canResumeAll {
                QueueControls()
            }
            if let balance = summary.balance {
                Divider()
                Text(balance)
                    .font(.callout)
                    .monospacedDigit()
            }
            if let warning = LowCreditWarning.text(for: connection.state, threshold: lowCreditThreshold) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(Theme.warning)
            }
            Divider()
            HStack {
                Button("Open Jutsu Studio") { system.showMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }
}

private struct MenuBarJobRow: View {
    let row: JobRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(row.progressText ?? row.statusLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            if let progress = row.progress {
                RenderProgress(value: progress)
            } else if let estimate = row.timeEstimate {
                EstimatedProgress(estimate: estimate)
            } else if let note = row.note {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }
}

/// The status item: the app mark as a template image, outlined while idle and filled while jobs run.
/// It hands the window action to `SystemIntegration` whenever it is shown.
struct MenuBarLabel: View {
    @Environment(LiveJobs.self) private var liveJobs
    @AppStorage(AppSettings.showActiveCountKey) private var showsCount = AppSettings.defaultShowActiveCount
    let system: SystemIntegration

    var body: some View {
        let active = liveJobs.activeCount
        HStack(spacing: 2) {
            Image(active == 0 ? "MenuBarIdle" : "MenuBarRunning")
                .accessibilityLabel(MenuBarSummary.accessibilityLabel(activeCount: active))
            if let text = MenuBarSummary.countText(activeCount: active, isShown: showsCount) {
                Text(text)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .capturesOpenWindow(for: system)
    }
}
