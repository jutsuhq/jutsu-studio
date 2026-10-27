#if DEBUG
    import AppKit
    import JutsuCore
    import Presentation

    /// Launch hooks for checking the window lifecycle without clicking through the UI, compiled into Debug builds
    /// only and read from the environment, which a release build never looks at.
    @MainActor
    enum DebugLaunchHooks {
        /// `1`: starts as a login launch in menu bar mode does, with no window.
        static let startHiddenVariable = "JUTSU_DEBUG_START_HIDDEN"
        /// Seconds after launch at which every app window closes, as ⌘W on the last one does.
        static let closeWindowsVariable = "JUTSU_DEBUG_CLOSE_WINDOWS_AFTER"
        /// Seconds after launch at which the main window is shown as Open Jutsu Studio shows it, for checking the menu
        /// bar and the Dock after a start with no window.
        static let showWindowVariable = "JUTSU_DEBUG_SHOW_WINDOW_AFTER"
        /// `1`: the app starts nothing that reaches the Keychain, the network or the job store's jobs
        /// (`AppEnvironment.start`), so a checking launch can't prompt for the sign-in or resume a paid job. It shows
        /// the app as connected with an API key that is never used, so the window is the app's, not onboarding.
        nonisolated static let offlineVariable = "JUTSU_DEBUG_OFFLINE"
        /// `create`, `queue`, `library` or `settings`: the page the window opens on.
        static let pageVariable = "JUTSU_DEBUG_PAGE"

        private static var environment: [String: String] { ProcessInfo.processInfo.environment }

        static var startsHidden: Bool { environment[startHiddenVariable] == "1" }

        nonisolated static var isOffline: Bool { ProcessInfo.processInfo.environment[offlineVariable] == "1" }

        private nonisolated static let offlineKeyID = "debug-offline"

        /// Holds a placeholder key in memory and keeps nothing, so an offline launch never asks the Keychain. The key
        /// never reaches a provider: the offline launch doesn't activate the connection.
        struct OfflineVault: CredentialVault {
            func saveData(_ data: Data) throws {}
            func loadData() throws -> Data? {
                try JSONEncoder().encode(Credential.apiKey(id: offlineKeyID, secret: "unused"))
            }
            func delete() throws {}
        }

        /// The placeholder key's connection; reads no saved connection and changes none.
        struct OfflineMetadata: ConnectionMetadataStore {
            func load() -> ConnectionMetadata? {
                ConnectionMetadata(kind: .apiKey, displayName: offlineKeyID, plan: nil)
            }
            func save(_ metadata: ConnectionMetadata) {}
            func clear() {}
        }

        static func run(system: SystemIntegration, navigation: NavigationModel) {
            if let page = environment[pageVariable].flatMap(Screen.init(rawValue:)) { navigation.selection = page }
            if let seconds = environment[closeWindowsVariable].flatMap(Double.init) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    for window in NSApp.windows where SystemIntegration.isAppWindow(window) { window.performClose(nil) }
                }
            }
            if let seconds = environment[showWindowVariable].flatMap(Double.init) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    system.showMainWindow()
                }
            }
        }
    }
#endif
