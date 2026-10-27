import AppKit
import Observation
import Presentation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "System")

/// Keeps the Dock badge, App Nap and notifications in step with `LiveJobs`, and brings the main window back.
/// Rules live in `BackgroundPolicy` and `JobNotification`; this type only applies them.
@MainActor
final class SystemIntegration {
    /// The `WindowGroup` id; SwiftUI prefixes its window identifiers with it.
    static let mainWindowID = "main"

    /// Captured from the menu bar, the one SwiftUI scene that exists while every window is closed, and from
    /// the main window for when the menu bar item is hidden.
    var openWindow: OpenWindowAction?

    private let environment: AppEnvironment
    private let liveJobs: LiveJobs
    private let navigation: NavigationModel
    private let defaults: UserDefaults
    private let notifier = JobNotifier()
    private var tracker = JobTransitionTracker(since: .now)
    private var activity: (any NSObjectProtocol)?
    private var isStarted = false

    init(environment: AppEnvironment, defaults: UserDefaults = .standard) {
        self.environment = environment
        liveJobs = environment.liveJobs
        navigation = environment.navigation
        self.defaults = defaults
    }

    func installNotificationHandler() {
        notifier.install { [weak self] response in
            self?.respond(to: response)
        }
    }

    /// Starts observing. Jobs that finished before this call never notify.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        tracker = JobTransitionTracker(since: .now)
        observe()
    }

    func showSettings() {
        navigation.selection = .settings
        showMainWindow()
    }

    func showMainWindow() {
        NSApp.activate()
        let window = NSApp.windows.first { window in
            (window.identifier?.rawValue.hasPrefix(Self.mainWindowID) ?? false)
                && (window.isVisible || window.isMiniaturized)
        }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: Self.mainWindowID)
        } else {
            logger.error("Can't open the main window: no window action yet")
        }
    }

    /// Whether the main window shows a sheet, over which SwiftUI shows no other.
    var mainWindowHasSheet: Bool {
        NSApp.windows.contains { window in
            (window.identifier?.rawValue.hasPrefix(Self.mainWindowID) ?? false) && window.attachedSheet != nil
        }
    }

    /// Opens the job in the app, as the menu bar panel's rows do: an active job's row in the Queue.
    func showJob(_ jobID: UUID) {
        navigation.showInQueue(jobID)
        showMainWindow()
    }

    /// A click opens the job's screen; a button runs what the same button does in the app.
    private func respond(to response: JobNotification.Response) {
        let jobID = response.jobID
        switch response.action {
        case nil:
            switch response.destination {
            case .library: navigation.showInLibrary(jobID)
            case .queue: navigation.showInQueue(jobID)
            }
            showMainWindow()
        case .renderFinal?:
            // As the card menu's Render Final…: the result's page picks the resolution and quotes the price.
            navigation.showInLibrary(jobID)
            showMainWindow()
        case .showInFinder?:
            guard let file = response.resultFile else { return showJob(jobID) }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        case .retry?:
            showJob(jobID)
            retry(jobID)
        }
    }

    /// Runs the job's Retry, Retry download or Check again, whichever its Queue row offers now.
    private func retry(_ jobID: UUID) {
        guard let job = liveJobs.job(jobID), let command = QueueJobCommands(job).retry else { return }
        let (environment, kind) = (environment, job.providerKind)
        Task {
            if let message = await environment.perform(command, on: jobID, kind: kind) {
                environment.connection.alert = message
            }
        }
    }

    /// `withObservationTracking` fires once per registration, so each change registers again. Only state changes
    /// count: the badge, App Nap and notifications ignore progress.
    private func observe() {
        withObservationTracking {
            _ = liveJobs.stateRevision
        } onChange: {
            Task { @MainActor in self.observe() }
        }
        update()
    }

    private func update() {
        let jobs = liveJobs.active + liveJobs.recentFinished(limit: .max)
        NSApp.dockTile.badgeLabel = BackgroundPolicy.dockBadge(activeCount: liveJobs.activeCount)
        holdActivity(BackgroundPolicy.needsActivity(jobs))
        let notifications = tracker.update(jobs, preferences: AppSettings.notificationPreferences(in: defaults))
        if !notifications.isEmpty { notifier.post(notifications) }
    }

    /// Keeps App Nap from throttling polling; the Mac may still go to sleep when idle.
    private func holdActivity(_ isNeeded: Bool) {
        if isNeeded, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Generating videos")
        } else if !isNeeded, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}

private struct OpenWindowCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let system: SystemIntegration

    func body(content: Content) -> some View {
        content.onAppear { system.openWindow = openWindow }
    }
}

extension View {
    /// Hands this scene's window action to `system`, so notification clicks can reopen the main window.
    func capturesOpenWindow(for system: SystemIntegration) -> some View {
        modifier(OpenWindowCapture(system: system))
    }
}
