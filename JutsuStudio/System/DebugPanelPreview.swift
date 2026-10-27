#if DEBUG
    import AppKit
    import Presentation
    import SwiftUI
    import os

    private let log = Logger(subsystem: "com.jutsustudio", category: "Debug")

    /// Windows for checking the menu bar panel's design without a click in the menu bar (`DebugLaunchHooks`), compiled
    /// into Debug builds only. One shows `MenuBarContent` on the system glass of macOS 26 (a menu material before it,
    /// or with the fallback hook), as the extra's window does; the other shows the status item's images on a light and
    /// a dark menu bar. The app is activated, as a click on the extra does.
    @MainActor
    enum DebugPanelPreview {
        static let panelTitle = "Menu Bar Panel Preview"
        static let iconsTitle = "Menu Bar Icon Preview"
        private static var windows: [NSWindow] = []

        static func show(system: SystemIntegration, environment: AppEnvironment, agents: AgentService) {
            let content = MenuBarContent(system: system)
                .environment(environment)
                .environment(environment.liveJobs)
                .environment(environment.connection)
                .environment(agents)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
            let hosting = NSHostingView(rootView: content)
            let panel = window(title: panelTitle, content: background(for: hosting))
            panel.appearance = NSAppearance(named: .darkAqua)
            let icons = window(title: iconsTitle, content: NSHostingView(rootView: IconStrip()))
            Task {
                // Once the seeded jobs and the budget are in.
                try? await Task.sleep(for: .seconds(1.5))
                for (window, view) in [(panel, hosting as NSView), (icons, icons.contentView)] {
                    guard let view else { continue }
                    window.setContentSize(view.fittingSize)
                }
                // At the right, as the extra opens, or at the left when the pointer is there, which would light a row.
                let screen = NSScreen.main?.visibleFrame ?? .zero
                let width = panel.frame.width + 20 + icons.frame.width
                let right = NSRect(
                    x: screen.maxX - width - 40, y: screen.minY, width: width + 40, height: screen.height)
                let left = right.contains(NSEvent.mouseLocation) ? screen.minX + 40 : right.minX
                icons.setFrameTopLeftPoint(NSPoint(x: left, y: screen.maxY - 8))
                panel.setFrameTopLeftPoint(NSPoint(x: left + icons.frame.width + 20, y: screen.maxY - 8))
                for window in NSApp.windows where window.className == "NSStatusBarWindow" && window.frame.minY >= 0 {
                    log.notice("Status item at \(NSStringFromRect(window.frame), privacy: .public)")
                }
                icons.orderFrontRegardless()
                // Active and key, as the app and the extra's window are while it is open, so its controls draw so.
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }

        private static func background(for content: NSView) -> NSView {
            if #available(macOS 26, *), PanelLook.usesGlass {
                let glass = NSGlassEffectView()
                glass.cornerRadius = 18
                glass.contentView = content
                return glass
            }
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
            effect.layer?.masksToBounds = true
            content.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                content.topAnchor.constraint(equalTo: effect.topAnchor),
                content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            return effect
        }

        private static func window(title: String, content: NSView) -> NSPanel {
            let panel = KeyPanel(
                contentRect: NSRect(x: 0, y: 0, width: 330, height: 400),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.title = title
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.contentView = content
            windows.append(panel)
            return panel
        }
    }

    /// A borderless panel that can be key without activating the app, as the extra's window is.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// The status item's images idle and at a few steps of progress, on a light and a dark menu bar, at their size and
    /// three times it.
    private struct IconStrip: View {
        private let steps: [Double?] = [nil, 0, 0.25, 0.5, 0.75, 1]

        var body: some View {
            VStack(spacing: 0) {
                strip(isDark: false)
                strip(isDark: true)
            }
        }

        private func strip(isDark: Bool) -> some View {
            HStack(spacing: 18) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, progress in
                    VStack(spacing: 8) {
                        icon(progress, size: 18, isDark: isDark)
                        icon(progress, size: 54, isDark: isDark)
                    }
                }
            }
            .padding(14)
            .background(isDark ? Color(white: 0.13) : Color(white: 0.92))
        }

        private func icon(_ progress: Double?, size: CGFloat, isDark: Bool) -> some View {
            Image(nsImage: MenuBarIcon.image(progress: progress))
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(isDark ? Color.white : Color.black.opacity(0.85))
                .frame(width: size, height: size)
        }
    }
#endif
