import AppKit
import Presentation
import SwiftUI
import UserNotifications

/// Which job notifications post, and whether they play a sound.
struct NotificationSettingsView: View {
    @AppStorage(AppSettings.notifyOnDoneKey) private var onDone = AppSettings.defaultNotify
    @AppStorage(AppSettings.notifyOnProblemsKey) private var onProblems = AppSettings.defaultNotify
    @AppStorage(AppSettings.notificationSoundKey) private var playsSound = AppSettings.defaultNotificationSound
    /// The toggles below do nothing while macOS blocks the app's notifications, so that comes first.
    @State private var isBlockedBySystem = false

    var body: some View {
        SettingsSection(
            title: "Jobs",
            footer: String(
                localized: "System notifications. A paused job waits for you, e.g. for credits or a sign-in.")
        ) {
            if isBlockedBySystem {
                SettingsRow(
                    label: "Turned off in System Settings",
                    detail: String(localized: "macOS doesn't show Jutsu Studio notifications."),
                    isFirst: true
                ) {
                    Button("Open System Settings", action: openSystemSettings)
                        .buttonStyle(.secondaryAction)
                }
            }
            SettingsRow(label: "Done", isFirst: !isBlockedBySystem) {
                Toggle("Done", isOn: $onDone)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(label: "Failed, rejected or paused") {
                Toggle("Failed, rejected or paused", isOn: $onProblems)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(label: "Play sound") {
                Toggle("Play sound", isOn: $playsSound)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .disabled(!onDone && !onProblems)
            .opacity(onDone || onProblems ? 1 : 0.45)
        }
        .task { await readAuthorization() }
        // Back from System Settings with the switch flipped.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await readAuthorization() }
        }
    }

    /// Only an explicit "off" counts: before the first notification macOS hasn't asked yet.
    private func readAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        isBlockedBySystem = status == .denied
    }

    private func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
