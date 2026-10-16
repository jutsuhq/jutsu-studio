import AppKit
import JutsuCore
import Presentation
import SwiftUI

/// What the grid's menus and selection bar ask the Library to do.
@MainActor
struct LibraryCardActions {
    /// Runs the action with the result as a local job, downloading it first when it is only on Higgsfield.
    var withImported: (LibraryItemModel, @escaping @MainActor (Job) -> Void) -> Void
    var setStarred: (Bool, [LibraryItemModel]) -> Void
    /// Starts picking results to compare, with this one.
    var compare: (LibraryItemModel) -> Void
    /// Opens the result's page.
    var open: (LibraryItemModel) -> Void
    var toggleSelection: (LibraryEntry) -> Void
    var clearSelection: () -> Void
    /// Asks before deleting.
    var delete: ([LibraryItemModel]) -> Void
    var report: (UserMessage?) -> Void
    /// Asks for the resolution and price of the finals of a batch's starred drafts.
    var renderFinals: (LibraryBatch) -> Void
    /// Opens a copy of the result in another app, and brings an edited file back as its new version.
    var editInOtherApp: (UUID) -> Void
    var importEditedVersion: (UUID) -> Void
}

/// A result card's right-click menu: the result page's actions that make sense without opening it.
struct LibraryCardMenu: View {
    let item: LibraryItemModel
    let isSelected: Bool
    /// False while results are picked to compare.
    let canSelect: Bool
    let actions: LibraryCardActions

    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        if item.needsImport {
            Button("Download to Library", systemImage: "arrow.down.circle") { actions.withImported(item) { _ in } }
        }
        if environment.canStar(item) {
            Button(item.isStarred ? "Unstar" : "Star", systemImage: item.isStarred ? "star.slash" : "star") {
                actions.setStarred(!item.isStarred, [item])
            }
            .help(LibraryStar.help(isStarred: item.isStarred, syncsLike: environment.syncsLike(item)))
        }
        if item.outputFile != nil || item.needsImport {
            Button("Compare…", systemImage: "rectangle.split.2x1") { actions.compare(item) }
        }
        Button("Show in Finder", systemImage: "folder") {
            actions.withImported(item) { job in
                if let url = job.outputFile { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        if let url = item.outputFile { ShareFilesLink(files: [url]) }
        Button("Export Short Preview…", systemImage: "square.and.arrow.up") {
            actions.withImported(item) { job in
                guard let url = job.outputFile else { return }
                Task { actions.report(await ShortPreviewExport.run(for: url)) }
            }
        }
        .help("The first 5 seconds at 480p without sound, small enough to send in a messenger")
        if !item.spec.prompt.isEmpty {
            Button("Copy Prompt", systemImage: "text.quote") { NSPasteboard.general.copyText(item.spec.prompt) }
        }
        followUps
        if item.outputFile != nil, !item.needsImport {
            OutsideEditButtons(
                edit: { actions.editInOtherApp(item.id) }, importVersion: { actions.importEditedVersion(item.id) })
        }
        if canSelect {
            Divider()
            LibrarySelectButton(isSelected: isSelected) { actions.toggleSelection(.item(item)) }
        }
        if !item.needsImport {
            Divider()
            Button("Delete from Library…", systemImage: "trash", role: .destructive) { actions.delete([item]) }
        }
    }

    @ViewBuilder private var followUps: some View {
        if let remote = item.historyItem {
            Button("Edit Inputs", systemImage: "slider.horizontal.3") { navigation.edit(remote.spec()) }
                .help("Run these inputs again; the files Higgsfield still has aren't uploaded again")
        } else {
            if item.job.finalizeSpec(owner: environment.provider?.owner) != nil {
                // The result's page opens on the finalize, quotes it and asks about the cap.
                Button("Finalize in 1080p…", systemImage: "sparkles") { actions.open(item) }
                    .help("Open the result to finalize this draft in 1080p")
            } else if item.canRenderFinal {
                // The result's page picks the final's resolution, quotes its price and asks about the cap.
                Button("Render Final…", systemImage: "sparkles") { actions.open(item) }
                    .help("Open the result to render its final")
            }
            if item.spec.operation == nil {
                Button("Edit & Re-run", systemImage: "arrow.triangle.2.circlepath") {
                    navigation.edit(item.spec, parentID: item.id)
                }
            }
            SeedanceFollowUpButtons(item: item)
        }
    }
}

/// Edit… and Extend… of a downloaded result: Create opens with the result as the source on Seedance 2.5, and the
/// jobs queued from there record it as their parent.
struct SeedanceFollowUpButtons: View {
    let item: LibraryItemModel

    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        if let edit = item.job.followUp(.edit) {
            Button("Edit…", systemImage: "wand.and.stars") { navigation.edit(edit, parentID: item.id) }
                .help("Change this result as a prompt says, with Seedance 2.5")
        }
        if let extend = item.job.followUp(.extend) {
            Button("Extend…", systemImage: "arrow.right.to.line") { navigation.edit(extend, parentID: item.id) }
                .help("Continue this result past its last frame, with Seedance 2.5")
        }
    }
}

/// A batch card's right-click menu.
struct LibraryBatchMenu: View {
    let batch: LibraryBatch
    let isSelected: Bool
    let actions: LibraryCardActions

    var body: some View {
        LibrarySelectButton(isSelected: isSelected) { actions.toggleSelection(.batch(batch)) }
        let files = LibraryBulkActions(batch.items).files
        if !files.isEmpty { ShareFilesLink(files: files) }
        if batch.items.contains(where: \.canRenderFinal) {
            RenderFinalsButton(batch: batch) { actions.renderFinals(batch) }
        }
        Divider()
        let unstarred = batch.unstarred
        Button("Delete Unstarred…", systemImage: "trash", role: .destructive) { actions.delete(unstarred) }
            .disabled(unstarred.isEmpty)
            .help("Keep the starred results and delete the rest of this batch")
    }
}

/// Render Finals for Starred… on a batch card's menu and its comparison page; off until a draft is starred.
struct RenderFinalsButton: View {
    let batch: LibraryBatch
    let action: () -> Void

    var body: some View {
        let isEmpty = BatchFinals(batch).isEmpty
        Button(BatchFinals.menuTitle, systemImage: "sparkles", action: action)
            .disabled(isEmpty)
            .help(
                isEmpty
                    ? Text("Star the drafts to render as finals")
                    : Text("Render the starred drafts as finals at one resolution"))
    }
}

/// The menu of a card among several selected cards: the bulk actions, then Deselect All.
struct LibraryBulkMenu: View {
    let items: [LibraryItemModel]
    let actions: LibraryCardActions

    var body: some View {
        LibraryBulkButtons(items: items, actions: actions)
        Divider()
        Button("Deselect All", systemImage: "xmark.circle", action: actions.clearSelection)
    }
}

/// What the selection bar and a selected card's menu offer for the selected results.
struct LibraryBulkButtons: View {
    let items: [LibraryItemModel]
    let actions: LibraryCardActions

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let bulk = LibraryBulkActions(items)
        let starrable = items.filter(environment.canStar)
        if !starrable.isEmpty {
            let starsAll = LibraryBulkActions.starsAll(starrable)
            Button(starsAll ? "Star" : "Unstar", systemImage: starsAll ? "star" : "star.slash") {
                actions.setStarred(starsAll, starrable)
            }
        }
        if !bulk.files.isEmpty {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(bulk.files)
            }
            Button("Copy Videos", systemImage: "doc.on.doc") { NSPasteboard.general.copyFiles(bulk.files) }
                .hoverHint("Copy the video files to paste them into a folder or another app")
            ShareFilesLink(files: bulk.files)
        }
        if !bulk.deletable.isEmpty {
            Button("Delete from Library…", systemImage: "trash", role: .destructive) { actions.delete(bulk.deletable) }
        }
    }
}

/// Share… for result files: AirDrop, Messages, Mail and the other share services.
struct ShareFilesLink: View {
    let files: [URL]

    var body: some View {
        ShareLink(items: files) {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        .help("Send with AirDrop, Messages, Mail or another app")
    }
}

private struct LibrarySelectButton: View {
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(isSelected ? "Deselect" : "Select", systemImage: "checkmark.circle", action: toggle)
    }
}

/// The grid's results and its cards, in the order shown.
struct LibraryGrid {
    let items: [LibraryItemModel]
    let entries: [LibraryEntry]
}

extension View {
    /// Publishes what the Library menu does here. Delete (⌫, and Edit › Delete) on a focused card or page asks to
    /// delete too.
    func libraryCommands(_ commands: LibraryCommands) -> some View {
        focusedSceneValue(\.libraryCommands, commands)
            .onDeleteCommand(perform: commands.delete.map { delete in { delete() } })
    }

    /// The VoiceOver action that selects or deselects a card, as ⌘-click does; none while it can't be selected.
    func selectable(_ canSelect: Bool, isSelected: Bool, toggle: @escaping () -> Void) -> some View {
        accessibilityActions {
            if canSelect {
                Button(isSelected ? "Deselect" : "Select", action: toggle)
            }
        }
    }
}
