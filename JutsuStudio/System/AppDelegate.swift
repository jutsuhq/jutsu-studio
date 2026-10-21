import AppKit
import Presentation

/// Owns the composition root so app-level callbacks (quit, last window closed, notification clicks)
/// work even when no window is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var environment = AppEnvironment.launch()
    private(set) lazy var system = SystemIntegration(environment: environment)
    private(set) lazy var updater = SoftwareUpdater()
    private(set) lazy var agents = AgentService(environment: environment, system: system)

    /// The notification delegate has to be in place before launch finishes to receive the click that launched the app.
    func applicationWillFinishLaunching(_ notification: Notification) {
        system.installNotificationHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.verifyBundledFonts()
        if SmokeTest.isRequested {
            SmokeTest.finish()
            return
        }
        system.start()
        agents.start()
        // Resumes the queue even when no window is restored; `start()` runs once.
        Task { await environment.start() }
    }

    /// Finder's Open With and drops on the Dock icon. On a cold start this runs before any window exists,
    /// so the files wait in `NavigationModel.pendingOpens` until Create is on screen. A link in the app's own
    /// scheme (the sign-in page's "Open Jutsu Studio") only brings the window forward.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { !AppLink.isAppLink($0) }
        if !files.isEmpty { environment.navigation.open(files) }
        system.showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !BackgroundPolicy.keepsRunning(activeCount: environment.liveJobs.activeCount, images: environment.imageWork)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing started, so nothing to wait for; and the smoke test quits from a main-actor task, which the
        // later reply below would need and so never get.
        if SmokeTest.isRequested { return .terminateNow }
        let jobs = environment.liveJobs
        if let prompt = BackgroundPolicy.quitPrompt(
            activeCount: jobs.activeCount, submittingCount: jobs.submittingCount, images: environment.imageWork,
            reason: Self.quitReason())
        {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = prompt.message
            alert.informativeText = prompt.detail
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        quitAfterSubmits()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.navigation.saveDraft()
        agents.stop()
    }

    /// Set once the pending quit was answered, so the stop and its time limit can't both answer it.
    private var answeredQuit = false

    /// Lets submits already sent be answered before the app quits: one cut off without an idempotency key
    /// fails on next launch, and an image or character sheet submit cut off loses the job IDs it may have paid for.
    /// Finished images being saved are waited for too, since their links expire. The quit goes ahead after all of
    /// that or its time limit, whichever comes first, so work slow to finish can't hold the quit (or a logout) up.
    private func quitAfterSubmits() {
        answeredQuit = false
        let environment = environment
        Task {
            async let images: Void = environment.finishImageWork()
            await environment.engine.stop(finishingSubmitsWithin: BackgroundPolicy.submitGrace)
            await images
            answerQuit()
        }
        Task {
            try? await Task.sleep(for: BackgroundPolicy.submitGrace + .seconds(2))
            answerQuit()
        }
    }

    private func answerQuit() {
        guard !answeredQuit else { return }
        answeredQuit = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// The reason attribute of the quit Apple event being handled. The SDK imports these four-char
    /// constants as `Int` or `OSType` depending on the header, hence the conversions.
    private static func quitReason() -> QuitReason {
        let keyword = AEKeyword(truncatingIfNeeded: kAEQuitReason)
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            let code = event.attributeDescriptor(forKeyword: keyword)?.enumCodeValue
        else { return .user }
        switch code {
        case OSType(truncatingIfNeeded: kAELogOut), OSType(truncatingIfNeeded: kAEReallyLogOut):
            return .logOut
        case OSType(truncatingIfNeeded: kAEShowRestartDialog), OSType(truncatingIfNeeded: kAERestart):
            return .restart
        case OSType(truncatingIfNeeded: kAEShowShutdownDialog), OSType(truncatingIfNeeded: kAEShutDown):
            return .shutDown
        default:
            return .user
        }
    }
}
