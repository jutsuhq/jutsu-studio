import AppKit
import JutsuCore
import Persistence
import Presentation
import SwiftUI

/// What the grid shows once filtered, culled and folded into variant groups, with the catalog facts its cards and
/// keys need.
struct LibraryGridLayout {
    var rows: [LibraryGridRow]
    var entries: [LibraryEntry]
    /// The videos on screen in grid order; a collapsed group's other variants aren't among them.
    var videos: [LibraryItemModel]
    var images: [LibraryMediaItem]
    var groups: LibraryVariantGroups
    var index: LibraryCatalogIndex

    /// Every result on screen in grid order, a batch card's results each: what a selection may act on.
    var visibleIDs: [UUID] {
        rows.flatMap { row -> [UUID] in
            switch row {
            case .entry(let entry): entry.itemIDs
            case .image(let image): [image.id]
            }
        }
    }

    /// The results a card stands for: a batch card's every result, any other card itself.
    func itemIDs(ofCard id: UUID) -> [UUID] {
        for case .entry(let entry) in rows where entry.id == id { return entry.itemIDs }
        return [id]
    }
}

extension LibraryView {
    /// The culling keys as Settings › Shortcuts set them.
    var cullingKeys: [ShortcutAction: Shortcut] {
        var keys: [ShortcutAction: Shortcut] = [:]
        keys[.keep] = $keepShortcut
        keys[.reject] = $rejectShortcut
        keys[.clearCulling] = $clearCullingShortcut
        return keys
    }

    /// Arrows move the current card, Space previews it, and the culling keys act on the selection or, without one,
    /// on the current card, which then moves on.
    func gridKey(_ press: KeyPress, layout: LibraryGridLayout) -> KeyPress.Result {
        let cards = layout.rows.map(\.id)
        if press.modifiers.isEmpty, let move = LibraryCursor.Move(press.key) {
            cursor = LibraryCursor.moved(cursor, move, in: cards, columns: gridColumns)
            return .handled
        }
        if press.key == .space, press.modifiers.isEmpty, let cursor {
            return quickLook(card: cursor, in: layout)
        }
        guard let shortcut = Shortcut(press), let action = CullingAction.pressed(shortcut, assigned: cullingKeys)
        else { return .ignored }
        cull(action, in: layout)
        return .handled
    }

    /// The culling buttons and keys of the grid: the visible selection, else the current card.
    func cull(_ action: CullingAction, in layout: LibraryGridLayout) {
        let chosen = CullingTargets.resolve(
            visible: layout.visibleIDs, selected: selected.ids.union(imageSelected), current: nil)
        guard chosen.isEmpty else {
            cull(action, chosen, index: layout.index)
            return
        }
        guard let current = cursor else { return }
        let applied = cull(action, layout.itemIDs(ofCard: current), index: layout.index)
        // Taking a verdict back stays on the card; a verdict moves on to the next one.
        guard applied != .clear else { return }
        let leaves = applied == .reject && !filter.showsRejected
        cursor = LibraryCursor.advanced(after: current, in: layout.rows.map(\.id), leaves: leaves)
    }

    /// Records the change for ⌘Z and saves it to the catalog. Returns what was done: Keep or Reject pressed again
    /// on results that already have it clears it (`CullingAction.toggled`).
    @discardableResult
    func cull(_ action: CullingAction, _ ids: [UUID], index: LibraryCatalogIndex) -> CullingAction {
        let applied = action.toggled(against: ids.map(index.culling(of:)))
        guard let writes = cullingHistory.apply(applied, to: ids, in: index) else { return applied }
        saveCulling(writes)
        return applied
    }

    /// Takes back the last keep, reject or clear; the card it touched becomes the current one again.
    func undoCulling() {
        guard let writes = cullingHistory.undo() else { return }
        cursor = writes.keys.map(\.materialID).first
        saveCulling(writes)
    }

    private func saveCulling(_ writes: [MaterialReference: Culling]) {
        let store = environment.store
        Task {
            do {
                try await store.setCulling(writes)
            } catch {
                exportMessage = UserMessage(
                    title: String(localized: "Couldn't save keep or reject"), message: error.localizedDescription)
            }
        }
    }

    func makePrimary(_ id: UUID) {
        let store = environment.store
        Task {
            do {
                try await store.makeVariantPrimary(id)
            } catch {
                exportMessage = UserMessage(
                    title: String(localized: "Couldn't make this variant primary"),
                    message: error.localizedDescription)
            }
        }
    }

    /// Space on the current card: the video's file, or the image.
    private func quickLook(card id: UUID, in layout: LibraryGridLayout) -> KeyPress.Result {
        if let item = layout.videos.first(where: { $0.id == id }) { return quickLook(item) }
        guard let image = layout.images.first(where: { $0.id == id }) else { return .ignored }
        previewImage(image)
        return .handled
    }

    /// ⌘Z for culling while there is something to take back; in a text field it undoes the typing.
    @ViewBuilder var cullingUndoShortcut: some View {
        if cullingHistory.canUndo {
            TextAwareShortcut("Undo", key: "z", textAction: Selector(("undo:"))) { undoCulling() }
        }
    }

    /// Keep, Reject and Clear in a card's menu, for the card or the selection it belongs to.
    @ViewBuilder
    func cullingMenu(for ids: [UUID], in layout: LibraryGridLayout) -> some View {
        Divider()
        ForEach(CullingAction.allCases, id: \.self) { action in
            Button(
                ids.count > 1 ? String(localized: "\(action.title) \(ids.count) Results") : action.title,
                systemImage: action.systemImage
            ) { cull(action, ids, index: layout.index) }
        }
    }

    // MARK: Variant groups

    /// Show or hide a group's variants, make one its face, and compare them.
    @ViewBuilder
    func variantMenu(for id: UUID, in layout: LibraryGridLayout) -> some View {
        if let group = layout.groups.group(of: id), let members = layout.groups.members[group] {
            Divider()
            if expandedGroups.contains(group) {
                Button("Hide Variants", systemImage: "square.stack") { expandedGroups.remove(group) }
                if layout.groups.faces[group] != id {
                    Button("Make Primary", systemImage: "star.square") { makePrimary(id) }
                }
            } else {
                Button("Show \(members.count) Variants", systemImage: "square.stack.3d.down.right") {
                    expandedGroups.insert(group)
                }
            }
            Button("Compare Variants", systemImage: "rectangle.split.2x1") {
                compareVariants(group, members: members, in: layout)
            }
        }
    }

    /// Videos open as the comparison grid of the group; images step through it two at a time.
    private func compareVariants(_ group: UUID, members: [UUID], in layout: LibraryGridLayout) {
        if layout.videos.contains(where: { $0.id == members[0] }) {
            batchSelection = group
            return
        }
        let rows = members.compactMap { id in layout.images.first { $0.id == id } }
        Task {
            var images: [CompareImage] = []
            for row in rows {
                switch row {
                case .video:
                    continue
                case .localImage(let image):
                    if !environment.imageLibrary.unavailable.contains(image.id) { images.append(.saved(image)) }
                case .remoteImage(let image):
                    if let url = await downloaded(image) {
                        images.append(CompareImage(id: image.jobID, fileURL: url, prompt: image.prompt))
                    }
                }
            }
            comparingVariants = VariantCompare(images)
        }
    }

    /// The account image's file, downloading it first; `nil` when the download fails.
    private func downloaded(_ image: HistoryImageItem) async -> URL? {
        if let url = downloadedImages[image.jobID] { return url }
        guard let url = try? await environment.imageLibrary.download(image) else { return nil }
        downloadedImages[image.jobID] = url
        return url
    }

    /// The culling verdict, the variant count and the current card, over one card of the grid.
    func marks(for id: UUID, in layout: LibraryGridLayout) -> LibraryCardMarks {
        let group = layout.groups.group(of: id)
        return LibraryCardMarks(
            culling: layout.index.culling(of: id),
            variants: layout.groups.collapsedCount(of: id, expanded: expandedGroups),
            isPrimary: group.map { expandedGroups.contains($0) && layout.groups.faces[$0] == id } ?? false,
            isCurrent: cursor == id)
    }
}

/// Keep, Reject and Clear for the selection bars and the large viewer, each saying how many it applies to.
struct CullingButtons: View {
    let count: Int
    /// The verdict of the one result shown, lit on its button; `nil` for a selection.
    var current: Culling?
    let act: (CullingAction) -> Void

    var body: some View {
        ForEach(CullingAction.allCases, id: \.self) { action in
            let isCurrent = current == action.result && action != .clear
            Button(action.title, systemImage: action.systemImage) { act(action) }
                .labelStyle(.iconOnly)
                .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .hoverHint(count > 1 ? String(localized: "\(action.title) \(count) results") : action.title)
        }
    }
}

/// Kept and rejected badges, a collapsed group's count, and the ring of the card the arrow keys are on.
struct LibraryCardMarks: ViewModifier {
    let culling: Culling
    /// How many variants a collapsed group's face stands for.
    let variants: Int?
    /// The face of an expanded group.
    let isPrimary: Bool
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .opacity(culling == .rejected ? 0.45 : 1)
            .overlay(alignment: .top) {
                HStack(spacing: 4) {
                    if let variants { MediaTag(text: String(localized: "\(variants) variants")) }
                    if isPrimary { MediaTag(text: String(localized: "Primary")) }
                    switch culling {
                    case .kept: badge("checkmark", color: Theme.accent, label: String(localized: "Kept"))
                    case .rejected: badge("xmark", color: Theme.danger, label: String(localized: "Rejected"))
                    case .unreviewed: EmptyView()
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .top) {
                if isCurrent {
                    // On the tile's edge, where a selected or hovered card's border is, so the two never show as a
                    // double ring; around the whole card it also bent around the title and detail lines.
                    RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .aspectRatio(LibraryThumbnail.tileAspect, contentMode: .fit)
                        .allowsHitTesting(false)
                }
            }
    }

    private func badge(_ systemImage: String, color: Color, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(color)
            .frame(width: 17, height: 17)
            .background(Theme.scrim, in: Circle())
            .accessibilityLabel(label)
    }
}

extension LibraryCursor.Move {
    init?(_ key: KeyEquivalent) {
        switch key {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        default: return nil
        }
    }
}
