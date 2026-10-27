import AppKit
import Observation
import Presentation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "System")

/// Keeps the Dock badge, App Nap and notifications in step with `LiveJobs`, brings the main window back, and moves the
/// app in and out of the Dock in menu bar mode. Rules live in `BackgroundPolicy`, `MenuBarMode` and `JobNotification`;
/// this type only applies them.
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
    private var windowObserver: (any NSObjectProtocol)?
    /// A start with no window (`MenuBarMode.startsHidden`), while the launch goes on.
    private var hiddenStart = HiddenStart()

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
        observeWindows()
        updateDockPresence()
    }

    /// Settings › General › Run in the menu bar, read where it applies so a change counts at once.
    var runsInMenuBar: Bool { AppSettings.runsInMenuBar(in: defaults) }

    /// The windows of the launch are being closed: their close doesn't quit the app.
    var isStartingHidden: Bool { hiddenStart.isActive }

    /// Starts with no window (`HiddenStart`): the windows SwiftUI opened or restored for the launch are closed, and in
    /// menu bar mode the app stays out of the Dock. Called as the launch finishes; ends once it is over.
    func startHidden() {
        hiddenStart.begin()
        for window in NSApp.windows where Self.isAppWindow(window) { window.close() }
        updateDockPresence()
        Task { [weak self] in
            try? await Task.sleep(for: WindowLifecycle.launchSettles)
            self?.hiddenStart.end()
        }
    }

    /// Called by every app window as it appears, before it is visible; closes one a hidden start didn't ask for, and
    /// brings the app into the Dock for any other.
    func windowAppeared(_ window: NSWindow) {
        if hiddenStart.closes(Self.lifecycle(window)) {
            // Closed on the next turn, unseen until then: closed now, in the middle of SwiftUI's update, its views
            // never appear and never hand over the window action (`capturesOpenWindow`) the app opens windows with.
            window.alphaValue = 0
            DispatchQueue.main.async {
                window.close()
                // About's window is kept and shown again.
                window.alphaValue = 1
            }
            return
        }
        if MenuBarMode.dockPresence(isOn: runsInMenuBar, hasWindow: true) == .regular,
            NSApp.activationPolicy() != .regular
        {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// The main window exists, shown or about to be.
    var hasMainWindow: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix(Self.mainWindowID) ?? false }
    }

    /// An app window is on screen or in the Dock: not the menu bar panel, a hover hint or another panel.
    var hasAppWindow: Bool { NSApp.windows.contains(where: Self.isAppWindow) }

    static func isAppWindow(_ window: NSWindow) -> Bool {
        WindowLifecycle.isOpen(lifecycle(window))
    }

    static func lifecycle(_ window: NSWindow) -> WindowLifecycle.Window {
        WindowLifecycle.Window(
            isPanel: window is NSPanel, isTitled: window.styleMask.contains(.titled),
            isShown: window.isVisible || window.isMiniaturized)
    }

    /// In menu bar mode, out of the Dock and the app switcher while no window is open (`MenuBarMode.dockPresence`).
    func updateDockPresence() {
        let presence = MenuBarMode.dockPresence(isOn: runsInMenuBar, hasWindow: hasAppWindow)
        let policy: NSApplication.ActivationPolicy = presence == .accessory ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// A window closes before it leaves `NSApp.windows`, so the Dock is updated on the next turn.
    private func observeWindows() {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windowClosed() }
        }
    }

    private func windowClosed() {
        updateDockPresence()
    }

    func showSettings() {
        navigation.selection = .settings
        showMainWindow()
    }

    /// Brings the main window forward, or opens it; `false` when there is none and no window action to open one with.
    @discardableResult
    func showMainWindow() -> Bool {
        hiddenStart.end()
        // Into the Dock first: an accessory app's window opens behind the active app's. Activated on the next turn
        // after the change, or the menu bar can keep showing the previous app's menus.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async { NSApp.activate() }
        } else {
            NSApp.activate()
        }
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
            return false
        }
        return true
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

/// Hands the hosting window to `SystemIntegration.windowAppeared` once it is in one.
private struct WindowReporter: NSViewRepresentable {
    let system: SystemIntegration

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindow = { [system] window in system.windowAppeared(window) }
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {}

    final class ReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
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

    /// Tells `system` when this view's window appears, for the Dock in menu bar mode and a start with no window.
    func reportsWindow(to system: SystemIntegration) -> some View {
        background(WindowReporter(system: system).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
