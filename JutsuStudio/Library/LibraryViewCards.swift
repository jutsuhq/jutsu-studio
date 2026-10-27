import AppKit
import JutsuCore
import Persistence
import Presentation
import SwiftData
import SwiftUI
import os

extension LibraryView {
    // MARK: Cards

    func card(_ item: LibraryItemModel, in layout: LibraryGridLayout, now: Date) -> some View {
        let entries = layout.entries
        let entry = LibraryEntry.item(item)
        let isSelected = picker == nil && selected.contains(entry)
        // A `Button`, not a tap gesture, so the card is focusable and VoiceOver can press it.
        return Button {
            if picker == nil, imagePicker == nil {
                imageSelected = []
                cursor = item.id
                click(entry, in: entries) { open(item) }
            } else if picker != nil {
                pick(item)
            }
        } label: {
            LibraryCard(
                item: item, now: now,
                isImporting: item.historyItem.map { environment.importingHistory.contains($0.id) } ?? false,
                isPicked: picker?.isPicked(item.id) ?? false, isSelected: isSelected,
                onDeviceRun: environment.onDevice.run(for: item.id))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(item.accessibilityLabel(now: now))
        .accessibilityAddTraits(picker?.isPicked(item.id) == true || isSelected ? .isSelected : [])
        .selectable(picker == nil && imagePicker == nil, isSelected: isSelected) { selected.toggle(entry) }
        .resultFileDrag(cardID: entry.id, dragged: selected.dragged(entry, in: gridVideoItems(entries)))
        .contextMenu {
            if let chosen = bulkSelection(around: entry, in: entries) {
                LibraryBulkMenu(items: chosen, actions: cardActions)
                cullingMenu(for: chosen.map(\.id), in: layout)
            } else {
                LibraryCardMenu(
                    item: item, isSelected: isSelected, canSelect: picker == nil && imagePicker == nil,
                    actions: cardActions)
                cullingMenu(for: [item.id], in: layout)
            }
            variantMenu(for: item.id, in: layout)
        }
        // On the card itself: a focused button would otherwise take Space as a press.
        .onKeyPress(.space) { quickLook(item) }
    }

    /// The videos of `entries`, in grid order, for what a drag carries.
    func gridVideoItems(_ entries: [LibraryEntry]) -> [LibraryItemModel] {
        entries.flatMap(\.items)
    }

    func batchCard(_ batch: LibraryBatch, in entries: [LibraryEntry], now: Date) -> some View {
        let entry = LibraryEntry.batch(batch)
        let isSelected = picker == nil && selected.contains(entry)
        return Button {
            if picker == nil, imagePicker == nil {
                imageSelected = []
                cursor = batch.id
                click(entry, in: entries) { batchSelection = batch.id }
            } else if picker != nil {
                batchSelection = batch.id
            }
        } label: {
            BatchCard(batch: batch, now: now, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(batch.accessibilityLabel(now: now))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .selectable(picker == nil && imagePicker == nil, isSelected: isSelected) { selected.toggle(entry) }
        .resultFileDrag(cardID: entry.id, dragged: selected.dragged(entry, in: gridVideoItems(entries)))
        .contextMenu {
            if let chosen = bulkSelection(around: entry, in: entries) {
                LibraryBulkMenu(items: chosen, actions: cardActions)
            } else if picker == nil, imagePicker == nil {
                LibraryBatchMenu(batch: batch, isSelected: isSelected, actions: cardActions)
            }
        }
    }

    /// The selected results shown, when the card is one of several selected cards: its menu then acts on them all.
    func bulkSelection(around entry: LibraryEntry, in entries: [LibraryEntry]) -> [LibraryItemModel]? {
        guard picker == nil, imagePicker == nil else { return nil }
        return selected.bulkItems(around: entry, in: gridVideoItems(entries))
    }

    var cardActions: LibraryCardActions {
        LibraryCardActions(
            withImported: withImported, setStarred: setStarred,
            compare: { item in
                startComparing()
                pick(item)
            },
            open: open, toggleSelection: { selected.toggle($0) }, clearSelection: { selected.clear() },
            delete: { pendingDelete = $0 }, report: { exportMessage = $0 }, renderFinals: { finalsBatch = $0 },
            editInOtherApp: editInOtherApp, importEditedVersion: importEditedVersion,
            compareWithOriginal: originalCompare)
    }

    /// The Library menu over the grid acts on the selected results, as the selection bar does.
    func gridCommands(_ chosen: [LibraryItemModel]) -> LibraryCommands {
        let environment = environment
        let targets = LibraryMenuTargets(chosen) { environment.canStar($0) }
        let actions = cardActions
        var commands = LibraryCommands()
        if !targets.starrable.isEmpty {
            commands.star = MenuCommand(title: targets.starTitle) {
                actions.setStarred(targets.starsAll, targets.starrable)
            }
        }
        if let item = targets.renderFinal {
            // The result's page picks the final's resolution, quotes its price and asks about the cap.
            commands.renderFinal = MenuCommand(title: String(localized: "Render Final…")) { actions.open(item) }
        }
        if !targets.deletable.isEmpty {
            commands.delete = { actions.delete(targets.deletable) }
        }
        return commands
    }

    // MARK: Actions

    /// ⌘-click toggles the card in the selection and ⇧-click extends it; a plain click clears it and opens the card.
    /// The grid takes the keyboard back from the search field, so the culling keys work on it.
    func click(_ entry: LibraryEntry, in entries: [LibraryEntry], open: () -> Void) {
        hasKeyboard = true
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command) {
            selected.click(entry, .toggle, in: entries)
        } else if flags.contains(.shift) {
            selected.click(entry, .extend, in: entries)
        } else {
            selected.clear()
            open()
        }
    }

    func startComparing() {
        selected.clear()
        picker = ComparePicker()
    }

    /// Deleted results leave the selection; one whose file couldn't be moved to the Trash stays in the library.
    func delete(_ items: [LibraryItemModel]) {
        let ids = Set(items.map(\.id))
        let records = records.filter { ids.contains($0.id) }
        selected.clear()
        Task { exportMessage = await environment.deleteFromLibrary(items, records: records) }
    }

    func setStarred(_ isStarred: Bool, _ items: [LibraryItemModel]) {
        let records = records
        Task {
            do {
                try await environment.setStarred(isStarred, items, records: records)
            } catch {
                exportMessage = .likeNotSaved(error)
            }
        }
    }

    /// A result only on Higgsfield is downloaded into the library first, then opens like any other.
    func open(_ item: LibraryItemModel) {
        withImported(item) { selection = $0.id }
    }

    /// Runs `action` with the item as a local job, downloading it first when it is only on Higgsfield.
    func withImported(_ item: LibraryItemModel, _ action: @escaping @MainActor (Job) -> Void) {
        guard let remote = item.historyItem else {
            action(item.job)
            return
        }
        guard !environment.importingHistory.contains(remote.id) else { return }
        Task {
            do {
                action(try await environment.importHistory(remote))
            } catch {
                exportMessage =
                    UserMessage(error, kind: .account)
                    ?? UserMessage(
                        title: String(localized: "Can't download this video"),
                        message: String(localized: "Try again in a moment."))
            }
        }
    }

    /// Compare plays local files, so a result still on Higgsfield is downloaded first and picked once it's in.
    /// It keeps its ID through the import, and a pick cancelled meanwhile stays cancelled.
    func pick(_ item: LibraryItemModel) {
        if item.outputFile != nil {
            picker?.toggle(item.id)
        } else if item.needsImport {
            withImported(item) { job in picker?.toggle(job.id) }
        }
    }

    /// Space previews the focused card's file, as in Finder; the arrow keys then step through the grid's results.
    func quickLook(_ item: LibraryItemModel) -> KeyPress.Result {
        if item.needsImport {
            withImported(item) { quickLookURL = $0.outputFile }
            return .handled
        }
        guard let url = item.outputFile else { return .ignored }
        quickLookURL = quickLookURL == url ? nil : url
        return .handled
    }

}
