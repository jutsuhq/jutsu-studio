import Presentation
import SwiftUI

/// Onboarding until a connection exists, then the app. Settings (⌘,) opens before a connection too, as a page
/// over the onboarding. Owns the sign-in sheet and the connection alerts, so they also work when signing in
/// again from Settings.
struct MainWindow: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(\.openURL) private var openURL
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        Group {
            if connection.state.isConnected {
                RootView()
            } else if navigation.selection == .settings {
                SettingsView()
                    .overlay(alignment: .topLeading) { backToOnboarding }
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Theme.background)
        // Signing out (usually from Settings) leads to sign-in, not to Settings over the onboarding.
        .onChange(of: connection.state.isConnected) { wasConnected, isConnected in
            if wasConnected, !isConnected { navigation.selection = .create }
        }
        .sheet(isPresented: signInSheetPresented) {
            SignInSheet()
                .preferredColorScheme(.dark)
        }
        .alert(
            connection.alert?.title ?? "", isPresented: Binding(isPresenting: alertBinding),
            presenting: connection.alert
        ) { message in
            switch message.action {
            case .openSettings:
                Button("Open Settings") { navigation.selection = .settings }
                Button("OK", role: .cancel) {}
            case .openConsole:
                Button("Open Console") { openURL(Higgsfield.consoleURL) }
                Button("OK", role: .cancel) {}
            case nil:
                Button("OK", role: .cancel) {}
            }
        } message: { message in
            Text(message.message)
        }
    }

    /// Beside the window buttons, where the sidebar toggle sits once connected.
    private var backToOnboarding: some View {
        Button {
            navigation.selection = .create
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.iconAction)
        .hoverHint("Back")
        .accessibilityLabel("Back")
        .padding(.leading, 78)
        .padding(.top, 5)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var signInSheetPresented: Binding<Bool> {
        Binding(
            get: { connection.activity.isSigningIn },
            set: { isPresented in
                if !isPresented { connection.cancelSignIn() }
            })
    }

    private var alertBinding: Binding<UserMessage?> {
        Binding(get: { connection.alert }, set: { connection.alert = $0 })
    }
}
