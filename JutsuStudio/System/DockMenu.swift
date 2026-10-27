import AppKit
import Presentation

/// The Dock icon's menu: the menu bar panel's key actions, for when the system hides the extra or it is turned off.
/// Built each time the menu opens, so its items are enabled as things stand.
@MainActor
enum DockMenu {
    static func make(environment: AppEnvironment, system: SystemIntegration) -> NSMenu {
        let navigation = environment.navigation
        let menu = NSMenu()
        // Enabled as built: each item is its own target, which would enable every one.
        menu.autoenablesItems = false
        menu.addItem(ActionItem(String(localized: "Open Jutsu Studio")) { system.showMainWindow() })
        for screen in [Screen.queue, .library] {
            menu.addItem(
                ActionItem(screen.title) {
                    navigation.selection = screen
                    system.showMainWindow()
                })
        }
        menu.addItem(.separator())
        menu.addItem(
            ActionItem(String(localized: "Pause All"), isEnabled: environment.canPauseAll) {
                environment.runOnAllJobs { await $0.pauseAll() }
            })
        menu.addItem(
            ActionItem(String(localized: "Resume All"), isEnabled: environment.canResumeAll) {
                environment.runOnAllJobs { await $0.resumeAll() }
            })
        menu.addItem(.separator())
        menu.addItem(ActionItem(String(localized: "Settings…")) { system.showSettings() })
        return menu
    }

    /// A menu item that runs a closure; it is its own target.
    @MainActor
    private final class ActionItem: NSMenuItem {
        private let handler: @MainActor () -> Void

        init(_ title: String, isEnabled: Bool = true, handler: @escaping @MainActor () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
            self.isEnabled = isEnabled
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("ActionItem isn't decoded")
        }

        @objc private func run() {
            handler()
        }
    }
}
