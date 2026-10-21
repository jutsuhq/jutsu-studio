import Presentation
import SwiftUI

@main
struct JutsuStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppSettings.showInMenuBarKey) private var showInMenuBar = AppSettings.defaultShowInMenuBar

    // note: dark only, because `Theme` has no light palette; follow the system once it gets one.
    var body: some Scene {
        WindowGroup(id: SystemIntegration.mainWindowID) {
            MainWindow()
                .environment(environment)
                .environment(environment.connection)
                .environment(environment.liveJobs)
                .environment(environment.navigation)
                .environment(appDelegate.updater)
                .environment(appDelegate.agents)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await environment.start() }
                .capturesOpenWindow(for: appDelegate.system)
        }
        .modelContainer(environment.modelContainer)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
                CheckForUpdatesMenuItem(updater: appDelegate.updater)
            }
            // View › Toggle Sidebar (⌃⌘S), acting on the main window's split view.
            SidebarCommands()
            AppCommands(environment: environment, system: appDelegate.system)
            // Settings is a page of the main window, not a window of its own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.system.showSettings() }
                    .keyboardShortcut(",")
            }
            #if DEBUG
                DebugCommands(environment: environment)
            #endif
        }

        Window("About Jutsu Studio", id: AboutView.windowID) {
            AboutView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarContent(system: appDelegate.system)
                .environment(environment)
                .environment(environment.liveJobs)
                .environment(environment.connection)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        } label: {
            MenuBarLabel(system: appDelegate.system)
                .environment(environment.liveJobs)
        }
        .menuBarExtraStyle(.window)
    }

    /// Writes only a real change. The extra sets `isInserted` again on every scene update; written straight
    /// to `@AppStorage`, each set posts a defaults change that updates the scenes again, a loop that kept the
    /// main thread at 100% and starved every other main-actor task.
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { showInMenuBar },
            set: { isInserted in
                if isInserted != showInMenuBar { showInMenuBar = isInserted }
            })
    }

    /// Owned by the app delegate so quitting and notification clicks work with every window closed.
    private var environment: AppEnvironment { appDelegate.environment }
}
