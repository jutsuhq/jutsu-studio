import Foundation

/// Settings › General › Run in the menu bar: the app stays in the menu bar with no window, and leaves the Dock while
/// no window is open (ARCHITECTURE §6, Background). Off, the app keeps the rules it had before.
public enum MenuBarMode {
    /// Whether the app is in the Dock and the app switcher.
    public enum DockPresence: Sendable, Hashable {
        /// `NSApplication.ActivationPolicy.regular`.
        case regular
        /// `.accessory`: no Dock icon, not in the app switcher, windows still open.
        case accessory
    }

    /// What started the app, as far as its first window goes.
    public enum Launch: Sendable, Hashable {
        /// Finder, the Dock, `open`, a file or a link: the person asked for the app.
        case person
        /// Login Items (`SMAppService.mainApp`).
        case login
        /// The `jutsu` helper, because an agent's call found the app not running.
        case helper
    }

    /// Closing the last window: in menu bar mode the app always stays; otherwise while work runs
    /// (`BackgroundPolicy.keepsRunning`), or while the window a hidden start never showed is being closed.
    public static func keepsRunning(
        isOn: Bool, isStartingHidden: Bool = false, activeCount: Int, images: ImageWork = .none
    ) -> Bool {
        isOn || isStartingHidden || BackgroundPolicy.keepsRunning(activeCount: activeCount, images: images)
    }

    /// In menu bar mode the app leaves the Dock while no window is open, and comes back as soon as one opens.
    public static func dockPresence(isOn: Bool, hasWindow: Bool) -> DockPresence {
        isOn && !hasWindow ? .accessory : .regular
    }

    /// Whether the app starts with no window. The helper always starts it so: the agent works through the socket, and
    /// `show` opens the window when the person is to see something. At login only in menu bar mode, which the person
    /// chose; off, Open at login opens the window as before.
    public static func startsHidden(_ launch: Launch, isOn: Bool) -> Bool {
        switch launch {
        case .person: false
        case .login: isOn
        case .helper: true
        }
    }

    /// The menu bar extra is the way back to a closed window in menu bar mode, so the mode shows it whatever
    /// Show in menu bar says.
    public static func showsExtra(showInMenuBar: Bool, isOn: Bool) -> Bool {
        showInMenuBar || isOn
    }

    /// Show in menu bar once the extra sets its `isInserted` binding; the binding writes it only when it differs. The
    /// extra sets it again on every scene update, so only a real change counts, and never the `true` that menu bar mode
    /// forces: turning the mode off brings back what the person chose. A removal (⌘-dragging the extra out) turns Show
    /// in menu bar off.
    public static func showInMenuBar(afterInserting isInserted: Bool, showInMenuBar: Bool, isOn: Bool) -> Bool {
        isInserted == showsExtra(showInMenuBar: showInMenuBar, isOn: isOn) ? showInMenuBar : isInserted
    }
}
