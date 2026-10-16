import AppKit
import Presentation
import SwiftUI

/// The About window. Its hero is one of the brand moments that carries the full signature gradient.
struct AboutView: View {
    static let windowID = "about"

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            hero
            details
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
    }

    private var hero: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text("Jutsu Studio")
                .font(.display(34))
                .kerning(0.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.text)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 44)
        .padding(.bottom, Theme.Spacing.xLarge)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(gradient: Theme.signature, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    // Fades into the page so the name sits on a darker band.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.45), .init(color: Theme.background, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()
        }
    }

    private var details: some View {
        VStack(spacing: Theme.Spacing.small) {
            Text(AboutContent.versionText(info: Bundle.main.infoDictionary))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .textSelection(.enabled)
            Text(AboutContent.disclaimer)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 2) {
                Text(AboutContent.license)
                Text(AboutContent.fontCredit)
                Text(AboutContent.updaterCredit)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.faint)
            if let repository = AboutContent.repository {
                Button("github.com/jutsuhq/jutsu-studio") { openURL(repository) }
                    .buttonStyle(.textLink)
                    .padding(.top, Theme.Spacing.xSmall)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Spacing.xLarge)
        .padding(.top, Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.xLarge)
    }
}

/// Replaces the standard About item, which would show AppKit's panel instead of `AboutView`.
struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Jutsu Studio") {
            NSApp.activate()
            openWindow(id: AboutView.windowID)
        }
    }
}

/// Software Update's menu item, dimmed while a check is under way and in Debug builds.
struct CheckForUpdatesMenuItem: View {
    let updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
