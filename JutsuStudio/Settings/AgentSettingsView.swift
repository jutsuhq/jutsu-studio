import JutsuCore
import Presentation
import SwiftUI

/// Settings › Agents: whether AI agents may drive the app through the bundled `jutsu` helper, what they may spend a
/// day, and the line that adds the helper to Claude Code.
struct AgentSettingsView: View {
    @Environment(AgentService.self) private var agents
    /// Read from the saved preferences, never through `@AppStorage`, which also reads launch arguments: the switch
    /// shows what the app enforces.
    @State private var isAllowed = AgentPreferences().isAllowed
    @State private var centsText = ""
    @State private var creditsText = ""
    @FocusState private var focus: ProviderKind?

    private let preferences = AgentPreferences()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Agents",
                footer: String(
                    localized: """
                        Lets an AI agent on this Mac, such as Claude Code, make videos within the budget below, \
                        follow their jobs and open the app's pages. Agents never see your API key or sign-in and can't delete anything. Turning this off \
                        refuses their next request and stops nothing already running.
                        """)
            ) {
                SettingsRow(label: "Allow agents", detail: statusText, isFirst: true) {
                    Toggle("Allow agents", isOn: $isAllowed)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            SettingsSection(
                title: "Daily agent budget",
                footer: String(
                    localized: """
                        What agents may spend a day; your daily cap still applies. 0 lets them look but not spend. \
                        A job over its limits waits in the Queue for you to confirm.
                        """)
            ) {
                budgetRow(String(localized: "With an API key (USD)"), kind: .apiKey, text: $centsText, isFirst: true)
                budgetRow(String(localized: "With an account (credits)"), kind: .account, text: $creditsText)
            }
            SettingsSection(
                title: "Claude Code",
                footer: String(localized: "Run this once in Terminal to add Jutsu Studio's tools to Claude Code.")
            ) {
                SettingsRow(label: "Command", isFirst: true) {
                    CopyButton(text: AgentService.claudeCommand)
                }
                Text(AgentService.claudeCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Theme.Spacing.large)
            }
        }
        .onChange(of: isAllowed) { _, isAllowed in
            preferences.setAllowed(isAllowed)
        }
        .onAppear {
            centsText = budgetText(for: .apiKey)
            creditsText = budgetText(for: .account)
        }
        .onChange(of: focus) { previous, _ in
            if let previous { commit(previous) }
        }
        .onDisappear {
            commit(.apiKey)
            commit(.account)
        }
    }

    private var statusText: String {
        switch agents.status {
        case .idle: String(localized: "Not started")
        case .listening: String(localized: "Ready for the jutsu helper")
        case .noAppGroup: String(localized: "Unavailable in a build without a team signature")
        case .failed(let reason): String(localized: "Can't listen for agents: \(reason)")
        }
    }

    private func budgetRow(
        _ label: String, kind: ProviderKind, text: Binding<String>, isFirst: Bool = false
    )
        -> some View
    {
        SettingsRow(label: label, isFirst: isFirst) {
            TextField(label, text: text)
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: kind)
                .themedField(isFocused: focus == kind)
                .frame(width: 110)
                .onSubmit { commit(kind) }
        }
    }

    private func budgetText(for kind: ProviderKind) -> String {
        AgentPreferences.budgetText(preferences.dailyBudget(for: kind), for: kind)
    }

    /// Keeps the last valid budget when the text doesn't parse.
    private func commit(_ kind: ProviderKind) {
        let text = kind == .apiKey ? centsText : creditsText
        if let amount = AgentPreferences.parseBudget(text, for: kind) {
            preferences.setDailyBudget(amount, for: kind)
        }
        let saved = budgetText(for: kind)
        if kind == .apiKey { centsText = saved } else { creditsText = saved }
    }
}
