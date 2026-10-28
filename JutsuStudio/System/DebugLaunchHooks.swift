#if DEBUG
    import AppKit
    import HiggsfieldProviders
    import JutsuCore
    import Presentation

    /// Launch hooks for checking the window lifecycle and the menu bar panel without clicking through the UI, compiled
    /// into Debug builds only and read from the environment, which a release build never looks at.
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
        /// `idle`, `running`, `needs`, `recent` or `all`: the menu bar panel shows made-up jobs, runs, agents and
        /// budget in that state (`DebugPanelSeed`). The jobs live in `LiveJobs` only and never reach the engine.
        static let panelVariable = "JUTSU_DEBUG_PANEL"
        /// A video the made-up results show as their file: a path the sandbox lets the app read, or a URL its
        /// thumbnails are read from as a remote result's are.
        static let panelMediaVariable = "JUTSU_DEBUG_PANEL_MEDIA"
        /// `1`: a window shows the menu bar panel's content and the status item's images (`DebugPanelPreview`): the
        /// extra's own window opens only on a click in the menu bar, which nothing in the app can send.
        static let previewVariable = "JUTSU_DEBUG_PANEL_PREVIEW"
        /// `1`: the panel uses the materials and bordered controls of macOS before 26.
        static let fallbackVariable = "JUTSU_DEBUG_PANEL_FALLBACK"
        /// `1`: the panel draws as with Reduce Transparency on.
        static let reduceTransparencyVariable = "JUTSU_DEBUG_REDUCE_TRANSPARENCY"
        /// `1`: once an account is connected, writes Debug › Export MCP Tool Catalog…'s JSON to standard output and
        /// quits, so a snapshot can be taken from a shell without the save panel (`docs/mcp-snapshots`).
        static let exportCatalogVariable = "JUTSU_DEBUG_EXPORT_CATALOG"

        private static var environment: [String: String] { ProcessInfo.processInfo.environment }

        static var startsHidden: Bool { environment[startHiddenVariable] == "1" }
        static var forcesMaterialFallback: Bool { environment[fallbackVariable] == "1" }
        static var reducesTransparency: Bool { environment[reduceTransparencyVariable] == "1" }
        static var panelState: DebugPanelSeed.State? { environment[panelVariable].flatMap(DebugPanelSeed.State.init) }

        /// The made-up runs on this Mac, in place of the real ones while a panel state is set.
        static var panelRuns: [MenuBarPanel.Run]? { panelState.map(DebugPanelSeed.runs) }

        /// The made-up agents and budget, while a panel state is set.
        static func seedPanel(_ input: inout MenuBarPanel.AgentsInput) {
            guard let panelState else { return }
            input = DebugPanelSeed.agents(panelState)
        }

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

        static func run(system: SystemIntegration, environment app: AppEnvironment, agents: AgentService) {
            if let page = environment[pageVariable].flatMap(Screen.init(rawValue:)) { app.navigation.selection = page }
            if let panelState {
                let media = environment[panelMediaVariable].flatMap {
                    $0.hasPrefix("/") ? URL(filePath: $0) : URL(string: $0)
                }
                for job in DebugPanelSeed.jobs(panelState, media: media) { app.liveJobs.apply(job) }
            }
            if environment[previewVariable] == "1" {
                DebugPanelPreview.show(system: system, environment: app, agents: agents)
            }
            if let seconds = environment[closeWindowsVariable].flatMap(Double.init) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    for window in NSApp.windows where SystemIntegration.isAppWindow(window) { window.performClose(nil) }
                }
            }
            if environment[exportCatalogVariable] == "1" { exportCatalog(app) }
            if let seconds = environment[showWindowVariable].flatMap(Double.init) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    system.showMainWindow()
                }
            }
        }

        /// Waits up to a minute for the account's provider and its signed-in account, then prints the catalog and
        /// quits; exits 1 on failure. The account's email and name are what the export redacts, so it never runs
        /// without them.
        private static func exportCatalog(_ app: AppEnvironment) {
            Task { @MainActor in
                var waits = 0
                while waits < 120, accountToRedact(app) == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                    waits += 1
                }
                guard let provider = app.provider as? HiggsfieldMCPProvider, let identifying = accountToRedact(app)
                else {
                    FileHandle.standardError.write(Data("No account connected.\n".utf8))
                    exit(1)
                }
                do {
                    let data = try await provider.exportCatalog(redacting: identifying)
                    FileHandle.standardOutput.write(data)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    exit(1)
                }
            }
        }

        /// The signed-in account's email and name once the account's provider is active; `nil` until then, and while
        /// the connection names neither.
        private static func accountToRedact(_ app: AppEnvironment) -> [String]? {
            guard app.provider is HiggsfieldMCPProvider, case .account(let info) = app.connection.state else {
                return nil
            }
            let identifying = [info.email, info.name].compactMap(\.self).filter { !$0.isEmpty }
            return identifying.isEmpty ? nil : identifying
        }
    }
#endif
