import Foundation
import JutsuCore

/// The results picked in the library grid for bulk actions. ⌘-click toggles a card, ⇧-click adds every card from
/// the last one toggled on to the clicked one, ⌘A picks every card shown. A batch card stands for all its results.
public struct LibrarySelection: Sendable, Hashable {
    public enum Click: Sendable, Hashable {
        /// ⌘-click.
        case toggle
        /// ⇧-click.
        case extend
    }

    /// The selected results.
    public private(set) var ids: Set<UUID> = []
    /// The card a ⇧-click extends from: the last one toggled on.
    public private(set) var anchor: UUID?

    public init() {}

    public var isEmpty: Bool { ids.isEmpty }

    /// A card is selected when all of its results are.
    public func contains(_ entry: LibraryEntry) -> Bool {
        let members = entry.itemIDs
        return !members.isEmpty && members.allSatisfy(ids.contains)
    }

    /// - Parameter entries: the grid's cards in order, for a range.
    public mutating func click(_ entry: LibraryEntry, _ click: Click, in entries: [LibraryEntry]) {
        switch click {
        case .toggle:
            toggle(entry)
        case .extend:
            guard let anchor, let start = entries.firstIndex(where: { $0.id == anchor }),
                let end = entries.firstIndex(where: { $0.id == entry.id })
            else {
                toggle(entry)
                return
            }
            for member in entries[min(start, end)...max(start, end)] {
                ids.formUnion(member.itemIDs)
            }
        }
    }

    public mutating func toggle(_ entry: LibraryEntry) {
        if contains(entry) {
            ids.subtract(entry.itemIDs)
            if anchor == entry.id { anchor = nil }
        } else {
            ids.formUnion(entry.itemIDs)
            anchor = entry.id
        }
    }

    public mutating func selectAll(_ entries: [LibraryEntry]) {
        ids = Set(entries.flatMap(\.itemIDs))
        anchor = entries.first?.id
    }

    public mutating func clear() {
        self = LibrarySelection()
    }

    /// The selected results among `items`, in their order. One the filters hide is left out, so a bulk action
    /// never touches a result that isn't on screen.
    public func items(in items: [LibraryItemModel]) -> [LibraryItemModel] {
        items.filter { ids.contains($0.id) }
    }

    /// The selected results among `items` when `entry` is one of several selected cards: its menu and a drag of it
    /// then act on them all. `nil` when the card acts alone.
    public func bulkItems(around entry: LibraryEntry, in items: [LibraryItemModel]) -> [LibraryItemModel]? {
        guard contains(entry) else { return nil }
        let chosen = self.items(in: items)
        return chosen.count > entry.itemIDs.count ? chosen : nil
    }

    /// The results whose files a drag of `entry` carries: every selected result when the card is one of several
    /// selected cards, else its own. A result with no downloaded file has nothing to drag and is left out; a card
    /// without one drags nothing.
    public func dragged(_ entry: LibraryEntry, in items: [LibraryItemModel]) -> [LibraryItemModel] {
        guard entry.items.contains(where: { $0.outputFile != nil }) else { return [] }
        return (bulkItems(around: entry, in: items) ?? entry.items).filter { $0.outputFile != nil }
    }
}

/// What the selection bar, and the menu of a card in a selection, can do with the selected results.
public struct LibraryBulkActions: Sendable, Hashable {
    public var items: [LibraryItemModel]

    public init(_ items: [LibraryItemModel]) {
        self.items = items
    }

    /// "3 selected".
    public var title: String {
        String(localized: "\(items.count) selected", bundle: .module)
    }

    /// Results in the library; one only on Higgsfield has no file or record to delete.
    public var deletable: [LibraryItemModel] { items.filter { !$0.needsImport } }

    /// The downloaded result files, for Show in Finder and Copy.
    public var files: [URL] { items.compactMap(\.outputFile) }

    /// Whether the star button stars `items` or unstars them: it stars them all unless every one is starred.
    public static func starsAll(_ items: [LibraryItemModel]) -> Bool {
        !items.allSatisfy(\.isStarred)
    }
}
