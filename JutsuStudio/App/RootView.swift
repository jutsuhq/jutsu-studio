import Presentation
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case create, queue, library, settings

    var id: Self { self }

    /// The pages listed at the top of the sidebar; Settings sits at its bottom.
    static let pages: [Screen] = [.create, .queue, .library]

    var title: String {
        switch self {
        case .create: String(localized: "Create")
        case .queue: String(localized: "Queue")
        case .library: String(localized: "Library")
        case .settings: String(localized: "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .create: "sparkles"
        case .queue: "square.stack.3d.up"
        case .library: "film"
        case .settings: "gearshape"
        }
    }

    /// The View menu item's shortcut, set in Settings › Shortcuts. Settings has ⌘, in the app menu.
    var shortcutAction: ShortcutAction? {
        switch self {
        case .create: .create
        case .queue: .queue
        case .library: .library
        case .settings: nil
        }
    }
}

struct RootView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(LiveJobs.self) private var liveJobs
    @Environment(ConnectionStore.self) private var connection
    @AppStorage(AppSettings.lowCreditThresholdKey) private var lowCreditThreshold =
        AppSettings.defaultLowCreditThreshold
    @FocusState private var isSidebarFocused: Bool
    /// Focus-visible: the ring shows once the arrow keys are used, not after a click.
    @State private var isKeyboardNavigating = false
    /// Kept per window across launches; the sidebar toggle and View › Toggle Sidebar (⌃⌘S) change it.
    @SceneStorage("sidebarCollapsed") private var isSidebarCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // A hand-built sidebar, not `List(selection:)`, which can't take the lime focus ring and queue badge;
    // `.focusable()` + `.onMoveCommand` below give it the same arrow-key behavior.
    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            VStack(alignment: .leading, spacing: 2) {
                BrandMark()
                    .padding(.horizontal, 6)
                    .padding(.bottom, 18)
                ForEach(Screen.pages) { screen in
                    row(for: screen)
                }
                Spacer(minLength: 0)
                if let plate = AccountPlate(connection: connection.state, lowCreditThreshold: lowCreditThreshold) {
                    AccountPlateView(plate: plate) { navigation.selection = .settings }
                        .padding(.bottom, Theme.Spacing.small)
                }
                row(for: .settings)
                    .hoverHint("Settings (⌘,)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity, alignment: .top)
            // Arrow keys move the selection, as they did with `List(selection:)`.
            .focusable()
            .focused($isSidebarFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: moveSelection)
            .background(Theme.background)
            // No toolbar: pages carry their own title and controls, so the window has no empty band on top.
            .toolbar(removing: .sidebarToggle)
            // Last: placed before `.toolbar(removing:)`, the widths never reached the column, which then opened
            // at the system's 140 pt minimum and wrapped the brand mark onto two lines.
            .navigationSplitViewColumnWidth(min: 228, ideal: 228, max: 320)
        } detail: {
            Group {
                switch navigation.selection {
                case .create?:
                    CreateView()
                case .queue?:
                    QueueView()
                case .library?:
                    LibraryView()
                case .settings?:
                    SettingsView()
                case nil:
                    EmptyView()
                }
            }
            .queuedToast()
        }
        // Beside the window buttons, where the system toggle sits in apps with a toolbar.
        .overlay(alignment: .topLeading) {
            SidebarToggle(isCollapsed: isSidebarCollapsed) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { isSidebarCollapsed.toggle() }
            }
            .padding(.leading, 78)
            .padding(.top, 5)
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isSidebarCollapsed ? .detailOnly : .all },
            set: { isSidebarCollapsed = $0 == .detailOnly })
    }

    private func row(for screen: Screen) -> some View {
        SidebarRow(
            title: screen.title, systemImage: screen.systemImage,
            isSelected: navigation.selection == screen,
            isFocused: isSidebarFocused && isKeyboardNavigating && navigation.selection == screen,
            badge: screen == .queue ? liveJobs.activeCount : 0
        ) {
            navigation.selection = screen
            isKeyboardNavigating = false
            isSidebarFocused = true
        }
    }

    /// Up and down step through the screens and stop at the ends; left and right do nothing.
    private func moveSelection(_ direction: MoveCommandDirection) {
        isKeyboardNavigating = true
        let screens = Screen.allCases
        let current = navigation.selection.flatMap { screens.firstIndex(of: $0) } ?? 0
        switch direction {
        case .up: navigation.selection = screens[max(current - 1, 0)]
        case .down: navigation.selection = screens[min(current + 1, screens.count - 1)]
        default: break
        }
    }
}

/// The titlebar button that shows and hides the sidebar.
private struct SidebarToggle: View {
    let isCollapsed: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovering ? Theme.text : Theme.muted)
                .frame(width: 26, height: 22)
                .background(
                    isHovering ? Theme.well : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .hoverHint(isCollapsed ? "Show Sidebar (⌃⌘S)" : "Hide Sidebar (⌃⌘S)")
        .accessibilityLabel(isCollapsed ? "Show Sidebar" : "Hide Sidebar")
    }
}
