import Foundation

/// Which of the app's windows the lifecycle rules count (ARCHITECTURE §6, Background), on what AppKit says of a
/// window, so the rules can be tested; `SystemIntegration` applies them.
public enum WindowLifecycle {
    /// What the rules need to know of an `NSWindow`.
    public struct Window: Sendable, Hashable {
        /// An `NSPanel`: the menu bar panel, a hover hint, an alert, an open or save panel.
        public var isPanel: Bool
        /// Has a title bar, as the main window and About do.
        public var isTitled: Bool
        /// Visible, or minimized to the Dock.
        public var isShown: Bool

        public init(isPanel: Bool, isTitled: Bool, isShown: Bool) {
            self.isPanel = isPanel
            self.isTitled = isTitled
            self.isShown = isShown
        }
    }

    /// SwiftUI opens and restores the windows of a launch before `applicationDidFinishLaunching`; this long after it
    /// the launch is taken as over, and a window that appears later is one the person asked for.
    public static let launchSettles: Duration = .milliseconds(500)

    /// The main window or About; not a panel, nor the untitled helper windows AppKit and SwiftUI keep.
    public static func isAppWindow(_ window: Window) -> Bool {
        !window.isPanel && window.isTitled
    }

    /// An app window the person sees, or can bring back from the Dock.
    public static func isOpen(_ window: Window) -> Bool {
        isAppWindow(window) && window.isShown
    }
}

/// A start with no window (`MenuBarMode.startsHidden`): every app window SwiftUI opens or restores during the launch is
/// closed as it appears, the main window and About alike, and that close doesn't quit the app. It ends once the launch
/// is over (`WindowLifecycle.launchSettles`) or the person asks for the window, so ⌘N and the like open one as usual.
public struct HiddenStart: Sendable, Hashable {
    public private(set) var isActive = false

    public init() {}

    public mutating func begin() {
        isActive = true
    }

    public mutating func end() {
        isActive = false
    }

    /// Whether `window`, appearing now, is closed.
    public func closes(_ window: WindowLifecycle.Window) -> Bool {
        isActive && WindowLifecycle.isAppWindow(window)
    }
}
