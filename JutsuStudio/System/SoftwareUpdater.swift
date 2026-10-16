import Foundation
import Observation
import Sparkle

/// Software Update through Sparkle. It reads the appcast attached to the latest GitHub release (`SUFeedURL`),
/// shows the release notes, downloads the DMG, checks it against `SUPublicEDKey` and the app's own signature, then
/// installs it and relaunches. The sandboxed app hands the install to Sparkle's installer service.
@MainActor
@Observable
final class SoftwareUpdater {
    /// Off in Debug builds: they have their own bundle ID, and an update would install the release in their place.
    #if DEBUG
        static let isEnabled = false
    #else
        static let isEnabled = true
    #endif

    /// False while a check or an install is under way, and always in a Debug build.
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?

    /// Once a day (`SUScheduledCheckInterval`); Sparkle keeps the choice in the app's defaults.
    var checksAutomatically: Bool {
        didSet { updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    /// Downloads a found update in the background and installs it when the app quits.
    var downloadsAutomatically: Bool {
        didSet { updater.automaticallyDownloadsUpdates = downloadsAutomatically }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        downloadsAutomatically = controller.updater.automaticallyDownloadsUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            // Sparkle changes it on the main thread.
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
                self?.lastCheck = updater.lastUpdateCheckDate
            }
        }
    }

    /// Check for Updates…: Sparkle's window shows the result, including "You're up to date".
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
