import AppKit
import JutsuCore
import Presentation
import ServiceManagement
import SwiftUI

/// Default mode, the menu bar item and menu bar mode, opening at login and Software Update.
struct GeneralSettingsView: View {
    @AppStorage(AppSettings.defaultModeKey) private var defaultMode = AppSettings.defaultMode
    @AppStorage(AppSettings.showInMenuBarKey) private var showInMenuBar = AppSettings.defaultShowInMenuBar
    @AppStorage(AppSettings.showActiveCountKey) private var showActiveCount = AppSettings.defaultShowActiveCount
    @AppStorage(AppSettings.runInMenuBarKey) private var runInMenuBar = AppSettings.defaultRunInMenuBar
    @AppStorage(AppSettings.promptHistoryClearedAtKey) private var promptHistoryClearedAt = 0.0
    @Environment(SoftwareUpdater.self) private var updater
    @State private var isConfirmingClearHistory = false
    @State private var loginItem = LoginItemStatus.disabled
    @State private var errorText = ""
    @State private var isShowingError = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Create",
                footer: String(localized: "The mode Create starts in when Jutsu Studio opens.")
            ) {
                SettingsRow(label: "Default mode", isFirst: true) {
                    SegmentedControl(
                        selection: $defaultMode,
                        options: Mode.allCases.filter { !$0.isVideoOperation }.map { ($0, $0.title) }
                    )
                    .fixedSize()
                }
                SettingsRow(
                    label: "Prompt history", detail: String(localized: "Starred prompts stay")
                ) {
                    Button("Clear History…") { isConfirmingClearHistory = true }
                        .buttonStyle(.secondaryAction)
                }
            }
            SettingsSection(title: "System", footer: systemFooter) {
                SettingsRow(label: "Show in menu bar", isFirst: true) {
                    Toggle(
                        "Show in menu bar",
                        isOn: Binding(
                            get: { MenuBarMode.showsExtra(showInMenuBar: showInMenuBar, isOn: runInMenuBar) },
                            set: { showInMenuBar = $0 })
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .disabled(runInMenuBar)
                SettingsRow(
                    label: "Run in the menu bar",
                    detail: String(localized: "Stays open with no window, without a Dock icon")
                ) {
                    Toggle("Run in the menu bar", isOn: $runInMenuBar)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRow(
                    label: "Active job count", detail: String(localized: "Next to the menu bar icon")
                ) {
                    Toggle("Active job count", isOn: $showActiveCount)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .disabled(!MenuBarMode.showsExtra(showInMenuBar: showInMenuBar, isOn: runInMenuBar))
                .opacity(MenuBarMode.showsExtra(showInMenuBar: showInMenuBar, isOn: runInMenuBar) ? 1 : 0.45)
                SettingsRow(label: "Open at login") {
                    HStack(spacing: Theme.Spacing.small) {
                        if loginItem == .requiresApproval {
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                .buttonStyle(.secondaryAction)
                        }
                        Toggle("Open at login", isOn: Binding(get: { loginItem.isOn }, set: setOpenAtLogin))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
            updates
        }
        .onAppear(perform: readLoginItem)
        // The user may allow or remove the login item in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginItem()
        }
        .confirmationDialog("Clear prompt history?", isPresented: $isConfirmingClearHistory) {
            Button("Clear History", role: .destructive) {
                promptHistoryClearedAt = Date().timeIntervalSince1970
            }
        } message: {
            Text("Prompts of earlier jobs leave the prompt picker. Starred prompts, jobs and the library stay.")
        }
        .alert("Can't change this setting", isPresented: $isShowingError) {
            Button("OK") {}
        } message: {
            Text(errorText)
        }
    }

    private var updates: some View {
        @Bindable var updater = updater
        return SettingsSection(title: "Updates", footer: updatesFooter) {
            SettingsRow(
                label: "Check automatically", detail: String(localized: "Once a day"),
                isFirst: true
            ) {
                Toggle("Check automatically", isOn: $updater.checksAutomatically)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(
                label: "Download and install automatically",
                detail: String(localized: "Installs when you quit")
            ) {
                Toggle("Download and install automatically", isOn: $updater.downloadsAutomatically)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .disabled(!updater.checksAutomatically)
            .opacity(updater.checksAutomatically ? 1 : 0.45)
            SettingsRow(label: AboutContent.versionText(info: Bundle.main.infoDictionary), detail: lastCheckText) {
                Button("Check Now") { updater.checkForUpdates() }
                    .buttonStyle(.secondaryAction)
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .disabled(!SoftwareUpdater.isEnabled)
    }

    /// What menu bar mode changes about opening at login, and the Login Items note when it needs approval.
    private var systemFooter: String {
        let mode =
            runInMenuBar
            ? String(localized: "In the menu bar, Jutsu Studio opens at login with no window.")
            : String(localized: "Closing the window quits Jutsu Studio unless jobs are running.")
        return [mode, loginItem.note].compactMap(\.self).joined(separator: " ")
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return String(localized: "Not checked yet") }
        return String(localized: "Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    private var updatesFooter: String {
        SoftwareUpdater.isEnabled
            ? String(
                localized:
                    "New versions come from the project's GitHub releases and are checked against its signing key before they install."
            )
            : String(localized: "Updates are off in development builds.")
    }

    private func readLoginItem() {
        loginItem = LoginItemStatus(SMAppService.mainApp.status)
    }

    private func setOpenAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorText = error.localizedDescription
            isShowingError = true
        }
        readLoginItem()
    }
}

extension LoginItemStatus {
    /// `notFound` means the app isn't registered, so the switch is off.
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        default: self = .disabled
        }
    }
}
