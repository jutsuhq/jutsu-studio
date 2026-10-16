import Foundation
import JutsuCore

/// One tile of the style gallery.
public struct PresetTileItem: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// `nil` for a selected preset the app knows nothing about.
    public var previewURL: URL?
    /// Played on hover; `nil` when the style has no example video.
    public var previewVideoURL: URL?
    public var isFavorite: Bool
    /// `false` when the catalog no longer has it: shown dimmed and can't be picked.
    public var isAvailable: Bool

    public init(
        id: UUID, name: String, previewURL: URL?, previewVideoURL: URL? = nil, isFavorite: Bool, isAvailable: Bool
    ) {
        self.id = id
        self.name = name
        self.previewURL = previewURL
        self.previewVideoURL = previewVideoURL
        self.isFavorite = isFavorite
        self.isAvailable = isAvailable
    }
}

/// A titled group of the style gallery.
public struct PresetGallerySection: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable, CaseIterable {
        /// The form's preset when it is in no other section, so it isn't hidden.
        case selected
        case favorites
        case recent
        case all
    }

    public var kind: Kind
    public var items: [PresetTileItem]

    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .selected: String(localized: "Selected", bundle: .module)
        case .favorites: String(localized: "Favorites", bundle: .module)
        case .recent: String(localized: "Recent", bundle: .module)
        case .all: String(localized: "All styles", bundle: .module)
        }
    }

    public init(kind: Kind, items: [PresetTileItem]) {
        self.kind = kind
        self.items = items
    }
}

/// Favorite and recent presets on top of the catalog. Both are stored as preset snapshots,
/// so one missing from a refreshed catalog keeps its name and can still be unstarred.
public enum PresetShelf {
    public static let recentLimit = 5
    public static let unknownPresetName = String(localized: "Unavailable style", bundle: .module)

    /// Selected (only when hidden elsewhere), favorites, recent, then the whole catalog; empty sections are left out.
    /// Every section is filtered by `query`. A preset is available only if `catalog` has it.
    public static func sections(
        catalog: [StylePreset], favorites: [StylePreset], recents: [StylePreset], selection: UUID?, query: String
    ) -> [PresetGallerySection] {
        sections(
            catalog: catalog, favorites: favorites, recents: recents, selections: selection.map { [$0] } ?? [],
            query: query)
    }

    /// `sections` for several selected presets, as a restyle batch has; they keep their order in Selected.
    public static func sections(
        catalog: [StylePreset], favorites: [StylePreset], recents: [StylePreset], selections: [UUID], query: String
    ) -> [PresetGallerySection] {
        let current = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favoriteIDs = Set(favorites.map(\.id))

        func item(_ snapshot: StylePreset) -> PresetTileItem {
            let preset = current[snapshot.id] ?? snapshot
            return PresetTileItem(
                id: preset.id, name: preset.name, previewURL: preset.previewURL,
                previewVideoURL: preset.previewVideoURL, isFavorite: favoriteIDs.contains(preset.id),
                isAvailable: current[preset.id] != nil)
        }

        let favoriteItems = distinct(favorites).map(item)
        let recentItems = distinct(recents).prefix(recentLimit).map(item)
        let allItems = distinct(catalog).map(item)

        var shown = Set((favoriteItems + recentItems + allItems).map(\.id))
        let selectedItems = selections.filter { shown.insert($0).inserted }.map {
            PresetTileItem(id: $0, name: unknownPresetName, previewURL: nil, isFavorite: false, isAvailable: false)
        }

        let sections: [(PresetGallerySection.Kind, [PresetTileItem])] = [
            (.selected, selectedItems), (.favorites, favoriteItems), (.recent, recentItems), (.all, allItems),
        ]
        return sections.compactMap { kind, items in
            let matching = items.filter { matches($0.name, query: query) }
            return matching.isEmpty ? nil : PresetGallerySection(kind: kind, items: matching)
        }
    }

    /// Whether `name` contains the trimmed query, ignoring case and accents; an empty query matches everything.
    public static func matches(_ name: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Unstars a favorite, or stars a catalog preset as the newest favorite. Unknown IDs change nothing.
    public static func toggledFavorite(_ id: UUID, favorites: [StylePreset], catalog: [StylePreset]) -> [StylePreset] {
        if favorites.contains(where: { $0.id == id }) {
            return favorites.filter { $0.id != id }
        }
        guard let preset = catalog.first(where: { $0.id == id }) else { return favorites }
        return [preset] + favorites
    }

    /// Moves the preset `id` to the front of `recents`, keeping `recentLimit` distinct presets.
    /// The snapshot comes from the catalog, else from the recents or favorites; with none, nothing changes.
    public static func recordingUse(
        _ id: UUID, recents: [StylePreset], catalog: [StylePreset], favorites: [StylePreset]
    ) -> [StylePreset] {
        guard let preset = (catalog + recents + favorites).first(where: { $0.id == id }) else { return recents }
        return Array(([preset] + recents.filter { $0.id != id }).prefix(recentLimit))
    }

    /// The stored list; empty for missing or unreadable data.
    public static func decode(_ data: Data?) -> [StylePreset] {
        data.flatMap { try? JSONDecoder().decode([StylePreset].self, from: $0) } ?? []
    }

    public static func encode(_ presets: [StylePreset]) -> Data {
        (try? JSONEncoder().encode(presets)) ?? Data()
    }

    private static func distinct(_ presets: [StylePreset]) -> [StylePreset] {
        var seen = Set<UUID>()
        return presets.filter { seen.insert($0.id).inserted }
    }
}
