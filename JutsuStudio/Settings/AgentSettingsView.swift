import JutsuCore
import Presentation
import SwiftUI

/// Settings › Agents: whether AI agents may drive the app through the bundled `jutsu` helper, what they may spend a
/// day, and the line that adds the helper to Claude Code.
struct AgentSettingsView: View {
    @Environment(AgentService.self) private var agents
    @State private var allowsUnlimited = AgentPreferences().allowsUnlimited
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
                    // `AgentService.isAllowed`, shared with the menu bar panel: read from the saved preferences,
                    // never through `@AppStorage`, which also reads launch arguments, so the switch shows what the
                    // app enforces.
                    Toggle("Allow agents", isOn: Binding(get: { agents.isAllowed }, set: { agents.setAllowed($0) }))
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
                title: "Unlimited generations",
                footer: String(
                    localized: """
                        Off, an agent's job that your plan's unlimited generations would pay for waits in the Queue \
                        for you to confirm. On, it runs without counting against the agent budget.
                        """)
            ) {
                SettingsRow(label: "Let agents use unlimited generations", isFirst: true) {
                    Toggle("Let agents use unlimited generations", isOn: $allowsUnlimited)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
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
        .onChange(of: allowsUnlimited) { _, allows in
            preferences.setAllowsUnlimited(allows)
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
