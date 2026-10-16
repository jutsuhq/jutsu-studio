import Foundation
import JutsuCore

/// The variants of one generation (a submit with a count of videos or images) on screen, each group folded into
/// one card that shows its face: the variant made primary, else the first in grid order. Built from the rows the
/// filters and the culling left, in one pass, so a group of one is just a card.
public struct LibraryVariantGroups: Sendable {
    /// Each group with two or more rows on screen, by group ID, its members in grid order.
    public private(set) var members: [UUID: [UUID]] = [:]
    /// The face of each group.
    public private(set) var faces: [UUID: UUID] = [:]
    private var groupOf: [UUID: UUID] = [:]

    public init(_ rows: [LibraryMediaItem], index: LibraryCatalogIndex) {
        self.init(ids: rows.map(\.id), index: index)
    }

    /// - Parameter ids: the rows on screen in grid order.
    public init(ids: [UUID], index: LibraryCatalogIndex) {
        var found: [UUID: [UUID]] = [:]
        for id in ids {
            if let group = index.entries[id]?.variantGroupID { found[group, default: []].append(id) }
        }
        for (group, ids) in found where ids.count > 1 {
            members[group] = ids
            faces[group] = ids.first { index.entries[$0]?.isVariantPrimary == true } ?? ids[0]
            for id in ids { groupOf[id] = group }
        }
    }

    /// The group a row on screen belongs to; `nil` for a row alone.
    public func group(of id: UUID) -> UUID? { groupOf[id] }

    /// Every row that belongs to a group on screen; such rows never fold into a batch card as well.
    public var groupedIDs: Set<UUID> { Set(groupOf.keys) }

    /// `rows` without the members of collapsed groups other than their face; expanded groups show them all.
    public func collapse<Row: Identifiable>(_ rows: [Row], expanded: Set<UUID>) -> [Row] where Row.ID == UUID {
        rows.filter { row in
            guard let group = groupOf[row.id], !expanded.contains(group) else { return true }
            return faces[group] == row.id
        }
    }

    /// How many variants a collapsed group's face stands for; `nil` for any other card.
    public func collapsedCount(of id: UUID, expanded: Set<UUID>) -> Int? {
        guard let group = groupOf[id], !expanded.contains(group), faces[group] == id else { return nil }
        return members[group]?.count
    }
}
