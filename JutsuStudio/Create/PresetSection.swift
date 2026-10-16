import Foundation
import Presentation
import SwiftUI

/// The restyle style gallery from the cached catalog, with search and a refresh button.
/// Picks one style, or toggles styles in and out of a batch.
struct PresetSection: View {
    /// The picked styles in order; one outside a batch.
    let selection: [UUID]
    /// Replaces the preset count, e.g. "3 / 12" in a batch.
    let detail: String?
    /// Why another style can't be added.
    let notice: String?
    let catalog: PresetCatalog?
    let onRefresh: () -> Void
    let onPick: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                SectionLabel(
                    title: detail == nil ? String(localized: "Style") : String(localized: "Styles"),
                    detail: detail ?? catalog.map { String(localized: "\($0.presets.count) presets") })
                Button {
                    onRefresh()
                } label: {
                    // A spinner while the list reloads: the catalog is usually unchanged, so nothing else moves.
                    Group {
                        if catalog?.isRefreshing ?? true {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(catalog?.isRefreshing ?? true)
                .hoverHint("Refresh styles")
                .accessibilityLabel("Refresh styles")
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            if let catalog {
                PresetGrid(catalog: catalog, selection: selection, onPick: onPick)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Favorites, recent presets and the whole catalog; favorites and recents are `PresetShelf` snapshots.
private struct PresetGrid: View {
    @Bindable var catalog: PresetCatalog
    let selection: [UUID]
    let onPick: (UUID) -> Void
    @AppStorage(AppSettings.favoritePresetsKey) private var favoritesData = Data()
    @AppStorage(AppSettings.recentPresetsKey) private var recentsData = Data()

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.small), GridItem(.flexible(), spacing: Theme.Spacing.small),
    ]

    var body: some View {
        let sections = PresetShelf.sections(
            catalog: catalog.presets, favorites: PresetShelf.decode(favoritesData),
            recents: PresetShelf.decode(recentsData), selections: selection, query: catalog.query)
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField("Search styles", text: $catalog.query)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, Theme.Spacing.medium)
                .frame(height: 32)
                .well()
            if let failure = catalog.refreshFailure {
                Text("\(failure.title). Showing the saved styles.")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }
            if catalog.presets.isEmpty && catalog.isRefreshing {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            ForEach(sections) { section in
                if sections.map(\.kind) != [.all] {
                    SectionLabel(title: section.title)
                }
                LazyVGrid(columns: columns, spacing: Theme.Spacing.small) {
                    ForEach(section.items) { item in
                        PresetTile(
                            item: item, isSelected: selection.contains(item.id), onPick: { onPick(item.id) },
                            onToggleFavorite: { toggleFavorite(item.id) })
                    }
                }
            }
        }
    }

    private func toggleFavorite(_ id: UUID) {
        let favorites = PresetShelf.toggledFavorite(
            id, favorites: PresetShelf.decode(favoritesData), catalog: catalog.presets)
        favoritesData = PresetShelf.encode(favorites)
    }
}

private struct PresetTile: View {
    let item: PresetTileItem
    let isSelected: Bool
    let onPick: () -> Void
    let onToggleFavorite: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onPick()
        } label: {
            Theme.well
                .frame(height: 76)
                .overlay {
                    RemoteThumbnail(url: item.previewURL, maxPixelSize: 480)
                }
                .overlay {
                    if isHovering, item.isAvailable, let video = item.previewVideoURL {
                        LoopingVideo(url: video)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        if !item.isAvailable {
                            MediaTag(text: String(localized: "Unavailable"))
                        }
                        MediaTag(text: item.name)
                    }
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 18, height: 18)
                            .background(Theme.accent, in: Circle())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .card(radius: Theme.Radius.field, isHighlighted: isSelected)
                .opacity(item.isAvailable ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        // A selected style that left the catalog can still be taken out of a batch.
        .disabled(!item.isAvailable && !isSelected)
        .hoverHint(item.isAvailable ? "" : "No longer available")
        .accessibilityLabel(item.isAvailable ? item.name : String(localized: "\(item.name), unavailable"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Outside the button so an unavailable favorite can still be unstarred.
        .overlay(alignment: .topLeading) {
            if item.isAvailable || item.isFavorite {
                TileButton(
                    systemImage: item.isFavorite ? "star.fill" : "star",
                    help: item.isFavorite
                        ? String(localized: "Remove from favorites") : String(localized: "Add to favorites"),
                    action: onToggleFavorite)
            }
        }
    }
}
