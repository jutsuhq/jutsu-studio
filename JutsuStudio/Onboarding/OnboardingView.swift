import AppKit
import Presentation
import SwiftUI

/// First launch: two ways to connect, side by side (prototype `#welcome`), under a centered hero.
struct OnboardingView: View {
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Hero()
                        .padding(.bottom, 36)
                    HStack(alignment: .top, spacing: Theme.Spacing.large) {
                        AccountCard()
                        APIKeyCard()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay { OrBadge() }
                    Label(
                        """
                        Jutsu Studio talks to Higgsfield directly. No account of ours, no telemetry. \
                        Unofficial, not affiliated with Higgsfield AI.
                        """,
                        systemImage: "lock.shield"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
                    .padding(.top, Theme.Spacing.xLarge)
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background { SignatureBackdrop() }
        .background(Theme.background)
    }
}

private struct Hero: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            GlowingAppIcon(size: 96)
                .padding(.bottom, Theme.Spacing.large)
            Text("Welcome to Jutsu Studio")
                .font(.system(size: 11, weight: .bold))
                .kerning(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.faint)
            Text("Connect Higgsfield")
                .font(.display(52))
                .textCase(.uppercase)
                .foregroundStyle(Theme.text)
            Text("Pick one way to connect. You can switch later in Settings.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
        }
        .multilineTextAlignment(.center)
    }
}

/// "or" on the seam between the two cards.
private struct OrBadge: View {
    var body: some View {
        Text("or")
            .font(.system(size: 11, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.muted)
            .frame(width: 32, height: 32)
            .background(Theme.background, in: Circle())
            .overlay { Circle().strokeBorder(Theme.stroke, lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

private struct AccountCard: View {
    @Environment(ConnectionStore.self) private var connection

    var body: some View {
        ConnectionCard(
            title: String(localized: "Higgsfield account"), systemImage: "person",
            badge: String(localized: "Subscription credits")
        ) {
            Text(
                """
                Spend the credits of your higgsfield.ai plan. You sign in on Higgsfield's own page through \
                its MCP server, so Jutsu Studio never sees your password.
                """
            )
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Benefit(String(localized: "Uses the credits you already pay for"))
                Benefit(String(localized: "Nothing to copy or paste"))
                Benefit(String(localized: "Your password stays on higgsfield.ai"))
            }
            .padding(.top, Theme.Spacing.xSmall)
            Spacer(minLength: Theme.Spacing.large)
            Button {
                connection.startSignIn()
            } label: {
                Label("Connect your Higgsfield account", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryAction)
        }
        .disabled(connection.activity != .idle)
    }
}

private struct APIKeyCard: View {
    @Environment(ConnectionStore.self) private var connection
    @State private var form = APIKeyForm()
    @FocusState private var focusedField: Field?

    private enum Field { case keyID, secret }

    var body: some View {
        ConnectionCard(
            title: String(localized: "API key"), systemImage: "key", badge: String(localized: "Pay as you go")
        ) {
            Text(
                """
                Billed per second of video from a prepaid balance in the Higgsfield console. \
                The key is kept in macOS Keychain.
                """
            )
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.Spacing.small) {
                TextField("Key ID", text: $form.keyID)
                    .focused($focusedField, equals: .keyID)
                    .themedField(isFocused: focusedField == .keyID)
                    .onSubmit { focusedField = .secret }
                SecureField("Secret", text: $form.secret)
                    .focused($focusedField, equals: .secret)
                    .themedField(isFocused: focusedField == .secret)
                    .onSubmit(connect)
            }
            .padding(.top, Theme.Spacing.xSmall)
            Spacer(minLength: Theme.Spacing.large)
            Button(action: connect) {
                HStack {
                    if connection.activity == .validatingKey {
                        ProgressView().controlSize(.small)
                    }
                    Label("Connect key", systemImage: "key")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryAction)
            .disabled(!form.isComplete || connection.activity != .idle)
            Link("Create a key in the Higgsfield console", destination: Higgsfield.consoleURL)
                .buttonStyle(.textLink)
        }
    }

    private func connect() {
        let submitted = form
        Task { await connection.connectAPIKey(submitted) }
    }
}

/// One way to connect (`.acct`): icon, title and a pill, then the content.
private struct ConnectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let badge: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.glassStroke, lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: Theme.Spacing.small)
                Pill(text: badge)
                    .fixedSize()
            }
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: Theme.Radius.card)
    }
}

/// A checkmarked line in a connection card.
private struct Benefit: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.text)
        } icon: {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Theme.accent)
        }
        .font(.system(size: 13))
    }
}
