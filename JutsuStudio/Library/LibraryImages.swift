import AppKit
import JutsuCore
import MediaKit
import Presentation
import SwiftUI

/// What the grid's image cards ask the Library to do, for images made on this Mac and ones still only on the
/// account. Remote images download first; the account stays their home unless they are downloaded to the library.
@MainActor
struct LibraryImageActions {
    /// Opens the files in Create as references.
    var useAsReferences: ([URL]) -> Void
    /// Opens Create's video side with the images, which asks for their role (`MakeVideoRequest`).
    var makeVideo: ([LibraryMediaItem]) -> Void
    /// Shows the image's prompt, what it was made from and the videos made from it.
    var showDetails: (LibraryMediaItem) -> Void
    /// Previews the file with Quick Look.
    var quickLook: (URL) -> Void
    /// Downloads the account image, then runs the action with its file.
    var withDownloaded: (HistoryImageItem, @escaping @MainActor (URL) -> Void) -> Void
    /// Stars or unstars saved images; the index keeps the stars.
    var setStarred: (Bool, [SavedImage]) -> Void
    /// Likes or unlikes account images.
    var setLiked: (Bool, [HistoryImageItem]) -> Void
    /// Starts picking images to compare, with this one.
    var compare: (LibraryMediaItem) -> Void
    /// Downloads the account image into the library.
    var downloadToLibrary: (HistoryImageItem) -> Void
    var toggleSelection: (UUID) -> Void
    var clearSelection: () -> Void
    /// Asks before moving to the Trash or removing from the library.
    var trash: (Set<UUID>) -> Void
    var remove: (Set<UUID>) -> Void
    var report: (UserMessage?) -> Void
    /// The round trip through another app, and a delivery set of the chosen images.
    var editInOtherApp: (UUID) -> Void
    var importEditedVersion: (UUID) -> Void
    var newDeliverySet: ([UUID]) -> Void
}

/// One saved image in the shared grid, as a card like a video's. An image whose file can't be found (its drive may
/// be disconnected) stays listed as unavailable until removed.
struct SavedImageCard: View {
    let image: SavedImage
    let isSelected: Bool
    /// Whether the file can be opened; one on a drive that isn't connected can't.
    let isAvailable: Bool
    @State private var picture: CGImage?

    var body: some View {
        ImageCardFrame(
            title: image.prompt, detail: imageCardDetail(model: image.model, date: image.createdAt),
            aspectRatio: image.aspectRatio.map(PixelSize.aspectLabel(of:)), isStarred: image.isStarred,
            isOnAccountOnly: false,
            isSelected: isSelected, picture: picture
        ) {
            if !isAvailable {
                VStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.title2)
                    Text("Can't be found")
                        .font(.caption)
                }
                .foregroundStyle(Theme.faint)
            }
        }
        .hoverHint(
            isAvailable
                ? image.prompt
                : String(
                    localized:
                        "The file isn't where it was saved. If it's on a drive that isn't connected, connect it to see the image again."
                )
        )
        .task(id: isAvailable ? image.fileURL : nil) {
            picture = isAvailable ? await ImageThumbnail.image(at: image.fileURL, maxPixelSize: 512) : nil
        }
    }
}

/// An account image in the shared grid, as a card like a video's: its picture from the account, or a spinner while
/// it loads. Decoded off the main thread at tile size (`RemoteImageCache`), never at full size.
struct RemoteImageCard: View {
    let image: HistoryImageItem
    let isSelected: Bool
    @State private var picture: CGImage?
    @State private var failed = false

    var body: some View {
        ImageCardFrame(
            title: image.prompt.isEmpty ? image.model : image.prompt,
            detail: imageCardDetail(model: image.model, date: image.createdAt),
            aspectRatio: image.aspectRatio, isStarred: image.isLiked, isOnAccountOnly: true,
            isSelected: isSelected, picture: picture
        ) {
            if failed {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text("Can't load the preview").font(.caption)
                }
                .foregroundStyle(Theme.faint)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .hoverHint(image.prompt.isEmpty ? image.model : image.prompt)
        .task(id: image.outputURL) {
            picture = await RemoteImageCache.shared.image(for: image.outputURL, maxPixelSize: 512)
            failed = picture == nil
        }
    }
}

/// "Higgsfield Soul 2.0 · 15 Oct 2026"; the aspect ratio is the tile's tag.
private func imageCardDetail(model: String, date: Date) -> String {
    ([model].filter { !$0.isEmpty } + [date.formatted(date: .abbreviated, time: .omitted)])
        .joined(separator: " · ")
}

/// The card both kinds of image share, built like `LibraryCard`: the same 16:9 tile, which a picture of another
/// shape fits over a blurred copy of itself (`FittedFrame`), the same tags and badges, one line of title and one of
/// detail. So images and videos in a row are the same size.
private struct ImageCardFrame<Placeholder: View>: View {
    let title: String
    let detail: String
    let aspectRatio: String?
    let isStarred: Bool
    /// Still only on the account, like a video that isn't downloaded yet.
    let isOnAccountOnly: Bool
    let isSelected: Bool
    let picture: CGImage?
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle()
                .fill(Theme.well)
                .aspectRatio(LibraryThumbnail.tileAspect, contentMode: .fit)
                .overlay {
                    if let picture {
                        FittedFrame(image: picture, tileAspect: LibraryThumbnail.tileAspect)
                    } else {
                        placeholder()
                    }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    MediaTag(text: String(localized: "Image")).padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if isStarred { badge("star.fill", label: String(localized: "Starred")) }
                        if isOnAccountOnly {
                            badge("icloud", label: String(localized: "On Higgsfield, not downloaded yet"))
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let aspectRatio { MediaTag(text: aspectRatio).padding(8) }
                }
                .overlay(alignment: .bottomLeading) {
                    if isSelected { SelectionCheck(label: "Selected") }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
                .card(radius: Theme.Radius.media, isHighlighted: isHovered || isSelected)
                .padding(.bottom, 7)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func badge(_ systemImage: String, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.accent)
            .frame(width: 17, height: 17)
            .background(Theme.scrim, in: Circle())
            .accessibilityLabel(label)
    }
}

/// An image card's right-click menu: the Images page's actions, now from the shared grid.
struct LibraryImageMenu: View {
    let row: LibraryMediaItem
    /// The selected images when the card is one of them; the menu then acts on them all.
    let chosen: [LibraryMediaItem]?
    let isSelected: Bool
    /// False while images are picked to compare.
    let canSelect: Bool
    /// Images whose file can't be opened right now.
    let unavailable: Set<UUID>
    let actions: LibraryImageActions

    /// The menu's images: the selection's when the card is one of several selected cards, else the card alone,
    /// split the way the old Images page split them: available images act on their files, missing ones don't.
    private var saved: [SavedImage] {
        let targets = chosen ?? [row]
        return targets.compactMap { if case .localImage(let image) = $0 { image } else { nil } }
    }

    var body: some View {
        switch row {
        case .video:
            EmptyView()
        case .localImage(let image):
            if unavailable.contains(image.id) {
                unavailableMenu(images: saved.filter { unavailable.contains($0.id) })
            } else {
                availableMenu(images: saved.filter { !unavailable.contains($0.id) })
            }
        case .remoteImage(let image):
            remoteMenu(for: image)
        }
    }

    /// The files can't be opened, so only their prompts, their stars and taking them off the library are offered.
    @ViewBuilder private func unavailableMenu(images: [SavedImage]) -> some View {
        starButtons(for: images)
        if images.count == 1 {
            Button("Details…") { actions.showDetails(row) }
        }
        if images.count == 1, let prompt = images.first?.prompt, !prompt.isEmpty {
            Button("Copy Prompt") { NSPasteboard.general.copyText(prompt) }
        }
        Divider()
        Button("Remove from Library…", role: .destructive) { actions.remove(Set(images.map(\.id))) }
    }

    @ViewBuilder private func availableMenu(images: [SavedImage]) -> some View {
        starButtons(for: images)
        Button(images.count > 1 ? "Make Video from \(images.count)…" : "Make Video…", systemImage: "film") {
            actions.makeVideo(images.map { .localImage($0) })
        }
        Button(images.count > 1 ? "Use \(images.count) as References" : "Use as Reference") {
            actions.useAsReferences(images.map(\.fileURL))
        }
        if images.count == 1 {
            Button("Details…") { actions.showDetails(row) }
        }
        Button("Compare…") { actions.compare(row) }
        if images.count == 1 {
            OutsideEditButtons(
                edit: { actions.editInOtherApp(row.id) }, importVersion: { actions.importEditedVersion(row.id) })
        }
        Button("Quick Look") { actions.quickLook(images[0].fileURL) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(images.map(\.fileURL)) }
        Divider()
        Button("Copy Image") { NSPasteboard.general.copyFiles(images.map(\.fileURL)) }
        if images.count == 1, !images[0].prompt.isEmpty {
            Button("Copy Prompt") { NSPasteboard.general.copyText(images[0].prompt) }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { actions.trash(Set(images.map(\.id))) }
        if canSelect {
            Divider()
            Button(isSelected ? "Deselect" : "Select", systemImage: "checkmark.circle") {
                actions.toggleSelection(row.id)
            }
        }
    }

    @ViewBuilder private func remoteMenu(for image: HistoryImageItem) -> some View {
        Button(image.isLiked ? "Unlike" : "Like", systemImage: image.isLiked ? "star.slash" : "star") {
            actions.setLiked(!image.isLiked, [image])
        }
        Button("Download to Library", systemImage: "arrow.down.circle") { actions.downloadToLibrary(image) }
        Button("Compare…") { actions.compare(row) }
        Button("Make Video…", systemImage: "film") { actions.makeVideo([row]) }
        Button("Use as Reference") {
            actions.withDownloaded(image) { url in actions.useAsReferences([url]) }
        }
        Button("Details…") { actions.showDetails(row) }
        Button("Quick Look") {
            actions.withDownloaded(image) { url in actions.quickLook(url) }
        }
        if !image.prompt.isEmpty {
            Button("Copy Prompt") { NSPasteboard.general.copyText(image.prompt) }
        }
        if canSelect {
            Divider()
            Button(isSelected ? "Deselect" : "Select", systemImage: "checkmark.circle") {
                actions.toggleSelection(row.id)
            }
        }
    }

    @ViewBuilder private func starButtons(for images: [SavedImage]) -> some View {
        let starsAll = images.allSatisfy(\.isStarred)
        Button(starsAll ? "Unstar" : "Star", systemImage: starsAll ? "star.slash" : "star") {
            actions.setStarred(!starsAll, images)
        }
    }
}

/// "2 images selected" with the bulk actions over the grid while images are selected; Escape clears them.
struct LibraryImageSelectionBar: View {
    let chosen: [LibraryMediaItem]
    let unavailable: Set<UUID>
    let onDone: () -> Void
    let actions: LibraryImageActions
    /// Keep, Reject or Clear on every chosen image.
    let cull: (CullingAction) -> Void

    private var saved: [SavedImage] {
        chosen.compactMap { if case .localImage(let image) = $0 { image } else { nil } }
    }

    private var remote: [HistoryImageItem] {
        chosen.compactMap { if case .remoteImage(let image) = $0 { image } else { nil } }
    }

    private var available: [SavedImage] { saved.filter { !unavailable.contains($0.id) } }
    private var missing: [SavedImage] { saved.filter { unavailable.contains($0.id) } }

    var body: some View {
        LibrarySelectionBar(title: title, onDone: onDone) {
            CullingButtons(count: chosen.count, act: cull)
            if !saved.isEmpty {
                Button(starsAll ? "Unstar" : "Star", systemImage: starsAll ? "star.slash" : "star") {
                    actions.setStarred(!starsAll, saved)
                }
            }
            if !remote.isEmpty {
                Button(likesAll ? "Unlike" : "Like", systemImage: likesAll ? "star.slash" : "star") {
                    actions.setLiked(!likesAll, remote)
                }
            }
            if !available.isEmpty || !remote.isEmpty {
                // Two images become a start and an end frame in one step, where the model takes them.
                Button("Make Video", systemImage: "film") {
                    actions.makeVideo(chosen.filter { row in !missing.contains { $0.id == row.id } })
                }
            }
            Button(DeliveryContent.newSetTitle, systemImage: "shippingbox") { actions.newDeliverySet(chosen.map(\.id)) }
            if !available.isEmpty {
                Button("Use as References", systemImage: "photo.badge.plus") {
                    actions.useAsReferences(available.map(\.fileURL))
                }
                if chosen.count == 2 {
                    Button("Compare", systemImage: "rectangle.split.2x1") {
                        actions.compare(chosen[0])
                        actions.compare(chosen[1])
                    }
                }
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    actions.trash(Set(available.map(\.id)))
                }
            }
            if !missing.isEmpty {
                Button("Remove from Library", systemImage: "minus.circle", role: .destructive) {
                    actions.remove(Set(missing.map(\.id)))
                }
            }
        }
    }

    private var title: String {
        String(localized: "\(chosen.count) images selected")
    }

    private var starsAll: Bool { saved.allSatisfy(\.isStarred) }
    private var likesAll: Bool { remote.allSatisfy(\.isLiked) }
}

struct ImageEmptyState: View {
    let origin: LibraryOrigin

    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        switch origin {
        case .local:
            EmptyState(
                systemImage: "photo.on.rectangle", title: "No images yet",
                detail: String(
                    localized:
                        "Images you make with Generate… in Create › References are saved here and in the Images folder of your output folder."
                )
            ) {
                Button("Go to Create") { navigation.selection = .create }
                    .buttonStyle(.secondaryAction)
            }
        case .higgsfield:
            EmptyState(
                systemImage: "photo.on.rectangle", title: "No images on Higgsfield yet",
                detail: String(localized: "Finished images from your account appear here once you make some."))
        }
    }
}

/// "Pick one more · Compare · Cancel" while images are being picked; Escape cancels.
struct ImageComparePickBar: View {
    let prompt: String
    /// False until both picks have files.
    let ready: Bool
    let onCancel: () -> Void
    let onCompare: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(prompt)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: Theme.Spacing.small)
            Button("Cancel", action: onCancel)
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
            Button("Compare", systemImage: "rectangle.split.2x1", action: onCompare)
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
        }
    }
}
