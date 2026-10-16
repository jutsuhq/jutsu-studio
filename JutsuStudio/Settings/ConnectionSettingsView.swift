import JutsuCore
import Presentation
import SwiftUI

/// The current connection with Sign Out / Remove.
struct ConnectionSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @State private var isConfirmingSignOut = false
    @State private var capabilities: Capabilities?
    @AppStorage(AppSettings.useUnlimitedKey) private var useUnlimited = AppSettings.defaultUseUnlimited

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            SettingsSection(
                title: "Higgsfield",
                footer: String(localized: "One connection at a time. To switch, sign out and connect the other one.")
            ) {
                details
            }
            if case .account = connection.state, let covered = capabilities?.unlimitedText {
                SettingsSection(
                    title: "Unlimited generations",
                    footer: String(
                        localized: """
                            Your plan has unlimited generations for these models right now. When this is on, their \
                            jobs use them instead of credits and don't count toward the daily cap. If they run out, \
                            Higgsfield charges credits as usual.
                            """)
                ) {
                    SettingsRow(label: "Use unlimited generations", detail: covered, isFirst: true) {
                        Toggle(String(localized: "Use unlimited generations"), isOn: $useUnlimited)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
            if connection.needsAttention {
                Label(
                    "Higgsfield refused this connection. Sign in again or connect another key.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.danger)
            }
            if let confirmation = SignOutConfirmation(connection.state) {
                HStack {
                    if case .account = connection.state {
                        Button("Sign In Again") { connection.startSignIn() }
                    }
                    Spacer()
                    Button(confirmation.confirmTitle, role: .destructive) { isConfirmingSignOut = true }
                }
                .buttonStyle(.secondaryAction)
            }
        }
        // Not `connection.state`: it changes with every balance refresh, which would blank the rows each time.
        .task(id: environment.providerGeneration) {
            capabilities = nil
            capabilities = await environment.capabilities()
        }
        .confirmationDialog(
            SignOutConfirmation(connection.state)?.title ?? "", isPresented: $isConfirmingSignOut,
            presenting: SignOutConfirmation(connection.state)
        ) { confirmation in
            Button(confirmation.confirmTitle, role: .destructive) {
                Task { await connection.signOut() }
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    @ViewBuilder private var details: some View {
        if connection.state.isConnected {
            let rows = connection.state.cardRows(capabilities: capabilities)
            ForEach(rows) { row in
                SettingsRow(label: row.label, isFirst: row.id == rows.first?.id) {
                    Text(row.value)
                        .font(.system(size: 13, design: row.isMonospaced ? .monospaced : .default))
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                }
            }
        } else {
            SettingsRow(
                label: "Not connected", value: String(localized: "Connect from the main window"),
                isFirst: true)
        }
    }
}
