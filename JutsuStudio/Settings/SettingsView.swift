import JutsuCore
import Presentation
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case connection, general, output, storage, spending, notifications, agents, shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .connection: String(localized: "Connection")
        case .general: String(localized: "General")
        case .output: String(localized: "Output")
        case .storage: String(localized: "Storage")
        case .spending: String(localized: "Spending")
        case .notifications: String(localized: "Notifications")
        case .agents: String(localized: "Agents")
        case .shortcuts: String(localized: "Shortcuts")
        }
    }
}

/// The Settings page of the main window: the app's tab switcher over themed cards, instead of a separate
/// window with the system tab toolbar and a grouped `Form` whose controls don't follow the theme.
struct SettingsView: View {
    @Environment(ConnectionStore.self) private var connection
    @State private var tab = SettingsTab.connection

    /// The spending cap belongs to a connection: USD for an API key, credits for an account.
    private var tabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0 != .spending || connection.state.isConnected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: "Settings",
                subtitle: String(localized: "Your Higgsfield connection, where results go and what you hear about."))
            // Eight tabs need more width than a minimum window with a widened sidebar has.
            ViewThatFits(in: .horizontal) {
                SegmentedControl(selection: $tab, options: tabs.map { ($0, $0.title) })
                    .fixedSize()
                FilterMenu(title: String(localized: "Settings"), selection: $tab, options: tabs.map { ($0, $0.title) })
            }
            .padding(.bottom, Theme.Spacing.xLarge)
            ScrollView {
                Group {
                    switch tab {
                    case .connection: ConnectionSettingsView()
                    case .general: GeneralSettingsView()
                    case .output: OutputSettingsView()
                    case .storage: StorageSettingsView()
                    case .spending: SpendingSettingsView(unit: connection.state.kind == .account ? .credits : .usd)
                    case .notifications: NotificationSettingsView()
                    case .agents: AgentSettingsView()
                    case .shortcuts: ShortcutSettingsView()
                    }
                }
                // Rows stay readable on a wide window instead of stretching label and control apart.
                .frame(maxWidth: 640, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Theme.Spacing.page)
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .navigationTitle("Settings")
        .onChange(of: tabs) { _, tabs in
            if !tabs.contains(tab) { tab = .connection }
        }
    }
}
