import AppKit
import JutsuMCP

/// Starts and activates the app through Launch Services, as `open -g` and `open -b` do.
struct WorkspaceLauncher: AppLauncher {
    @MainActor
    func start(_ app: URL, bundleID: String, arguments: [String]) async throws -> RunningApp {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return Self.following(running)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // In the background: the agent's own app stays in front, and the window shows only when `show` asks.
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = arguments
        let running = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        return Self.following(running)
    }

    /// `show` has ordered the window front; since macOS 14 the app itself may become active only when the active app
    /// lets it. Neither may this process, which isn't the active app either. Opening the running app through Launch
    /// Services, as `open -b` does, brings it forward.
    @MainActor
    func activate(bundleID: String) async {
        guard let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    @MainActor
    private static func following(_ app: NSRunningApplication) -> RunningApp {
        let pid = app.processIdentifier
        // Asked again on each check, by process ID, rather than through the object this actor owns.
        return RunningApp(launchDate: app.launchDate ?? .now) {
            kill(pid, 0) != 0 && errno == ESRCH
        }
    }
}
