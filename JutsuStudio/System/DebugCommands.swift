#if DEBUG
    import AppKit
    import HiggsfieldProviders
    import Presentation
    import SwiftUI
    import UniformTypeIdentifiers
    import os

    private let logger = Logger(subsystem: "com.jutsustudio", category: "Debug")

    /// The Debug menu, compiled into Debug builds only.
    struct DebugCommands: Commands {
        let environment: AppEnvironment

        var body: some Commands {
            CommandMenu("Debug") {
                Button("Export MCP Tool Catalog…") { exportCatalog() }
                    .disabled(accountProvider == nil)
            }
        }

        /// The provider while an account (not an API key) is connected.
        private var accountProvider: HiggsfieldMCPProvider? {
            environment.provider as? HiggsfieldMCPProvider
        }

        /// Saves `tools/list` and `models_explore` as JSON, to check the docs against the live server (issue #37).
        @MainActor
        private func exportCatalog() {
            guard let provider = accountProvider else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "mcp-catalog-\(Date().formatted(.iso8601.year().month().day())).json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            var identifying: [String] = []
            if case .account(let info) = environment.connection.state {
                identifying = [info.email, info.name].compactMap(\.self)
            }
            Task { @MainActor in
                do {
                    let data = try await provider.exportCatalog(redacting: identifying)
                    try data.write(to: url, options: .atomic)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    logger.error("Can't export the MCP catalog: \(String(describing: error), privacy: .private)")
                    let alert = NSAlert(error: error)
                    alert.messageText = String(localized: "Can't export the MCP tool catalog")
                    alert.runModal()
                }
            }
        }
    }
#endif
