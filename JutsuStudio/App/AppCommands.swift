import AppKit
import Presentation
import SwiftUI
import UniformTypeIdentifiers

/// The menu items beyond the system's: the pages (⌘1–⌘3), File › Open…, New from Template and Generate (⌘↩), and
/// the Library and Queue menus. Their shortcuts are the ones set in Settings › Shortcuts.
struct AppCommands: Commands {
    let environment: AppEnvironment
    let system: SystemIntegration
    @FocusedValue(\.createSubmit) private var submit
    @FocusedValue(\.libraryCommands) private var library
    @FocusedValue(\.queueCommands) private var queue
    @StoredShortcut(.open) private var openShortcut
    @StoredShortcut(.generate) private var generateShortcut
    @StoredShortcut(.create) private var createShortcut
    @StoredShortcut(.queue) private var queueShortcut
    @StoredShortcut(.library) private var libraryShortcut
    @StoredShortcut(.star) private var starShortcut
    @StoredShortcut(.deleteResult) private var deleteShortcut
    @StoredShortcut(.cancelJob) private var cancelJobShortcut
    @StoredShortcut(.retryJob) private var retryJobShortcut

    private var navigation: NavigationModel { environment.navigation }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") { openFiles() }
                .keyboardShortcut(openShortcut)
            // Menu-bar content gets no model container of its own, so it is handed one for the template list.
            NewFromTemplateMenu(environment: environment) { system.showMainWindow() }
                .modelContainer(environment.modelContainer)
            Divider()
            Button(submit?.title ?? String(localized: "Generate")) { submit?.action() }
                .keyboardShortcut(generateShortcut)
                .disabled(submit?.isEnabled != true)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Screen.pages) { screen in
                Button(screen.title) {
                    navigation.selection = screen
                    system.showMainWindow()
                }
                .keyboardShortcut(shortcut(for: screen))
            }
            Divider()
        }
        CommandMenu("Library") {
            menuItem(library?.star, placeholder: String(localized: "Star"), shortcut: starShortcut)
            menuItem(library?.renderFinal, placeholder: String(localized: "Render Final…"), shortcut: nil)
            Divider()
            Button("Delete from Library…") {
                // ⌘⌫ deletes to the start of the line while text is edited.
                if !TextFocus.send(#selector(NSResponder.deleteToBeginningOfLine(_:))) { library?.delete?() }
            }
            .keyboardShortcut(deleteShortcut)
            .disabled(library?.delete == nil)
        }
        CommandMenu("Queue") {
            QueueMenuControls(environment: environment)
            Divider()
            Button("Cancel Job") { queue?.cancel?() }
                .keyboardShortcut(cancelJobShortcut)
                .disabled(queue?.cancel == nil)
            menuItem(queue?.retry, placeholder: String(localized: "Retry Job"), shortcut: retryJobShortcut)
        }
    }

    /// A menu item for `command`, disabled and titled `placeholder` while it doesn't apply.
    private func menuItem(_ command: MenuCommand?, placeholder: String, shortcut: KeyboardShortcut?) -> some View {
        Button(command?.title ?? placeholder) { command?.action() }
            .keyboardShortcut(shortcut)
            .disabled(command == nil)
    }

    private func shortcut(for screen: Screen) -> KeyboardShortcut? {
        switch screen.shortcutAction {
        case .create?: createShortcut
        case .queue?: queueShortcut
        case .library?: libraryShortcut
        default: nil
        }
    }

    /// The Open With path: a video becomes the source, images become references.
    @MainActor
    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        navigation.open(panel.urls)
        system.showMainWindow()
    }
}

/// Queue › Pause All and Resume All, which apply wherever the window is, enabled like the Queue header's buttons.
private struct QueueMenuControls: View {
    let environment: AppEnvironment

    var body: some View {
        Button("Pause All") { environment.runOnAllJobs { await $0.pauseAll() } }
            .disabled(!environment.canPauseAll)
        Button("Resume All") { environment.runOnAllJobs { await $0.resumeAll() } }
            .disabled(!environment.canResumeAll)
    }
}

/// Create's main button as the Generate menu item sees it.
struct CreateSubmit {
    let title: String
    let isEnabled: Bool
    let action: @MainActor () -> Void
}

/// A menu item's title and action, published by the screen it acts on; `nil` disables the item.
struct MenuCommand {
    let title: String
    let action: @MainActor () -> Void
}

/// What the Library menu does on the open result or the selected results; `nil` items are disabled.
struct LibraryCommands {
    var star: MenuCommand?
    var renderFinal: MenuCommand?
    /// Asks before deleting.
    var delete: (@MainActor () -> Void)?
}

/// What the Queue menu does with the selected job; `nil` items are disabled.
struct QueueCommands {
    var cancel: (@MainActor () -> Void)?
    var retry: MenuCommand?
}

private struct CreateSubmitKey: FocusedValueKey {
    typealias Value = CreateSubmit
}

private struct LibraryCommandsKey: FocusedValueKey {
    typealias Value = LibraryCommands
}

private struct QueueCommandsKey: FocusedValueKey {
    typealias Value = QueueCommands
}

extension FocusedValues {
    /// Published by Create while it is on screen in the key window.
    var createSubmit: CreateSubmit? {
        get { self[CreateSubmitKey.self] }
        set { self[CreateSubmitKey.self] = newValue }
    }

    /// Published by Library's grid or result page while it is on screen.
    var libraryCommands: LibraryCommands? {
        get { self[LibraryCommandsKey.self] }
        set { self[LibraryCommandsKey.self] = newValue }
    }

    /// Published by the selected Queue row while the Queue is on screen.
    var queueCommands: QueueCommands? {
        get { self[QueueCommandsKey.self] }
        set { self[QueueCommandsKey.self] = newValue }
    }
}
