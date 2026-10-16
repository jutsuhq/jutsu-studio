import AppKit
import JutsuCore
import MediaKit
import Presentation
import SwiftUI
import UniformTypeIdentifiers

/// Reference images: a grid with remove and move buttons, filled by drop or the file picker.
struct ReferencesSection: View {
    @Binding var form: CreateForm
    let onPick: () -> Void
    /// Opens the account's uploaded images; `nil` without an account connection.
    var onBrowseUploads: (() -> Void)?
    /// The link being downloaded for this section, if any.
    var linkDownload: LinkDownload?
    let onPasteLink: () -> Void
    let onCancelLink: () -> Void
    /// Generate… and this session's generated images; `nil` while disconnected.
    var generation: ReferenceGeneration?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.small), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                SectionLabel(title: form.mode.referencesTitle, detail: form.referenceCountText)
                if let onBrowseUploads, form.canAddReferences {
                    Button("From Higgsfield", systemImage: "icloud.and.arrow.down", action: onBrowseUploads)
                        .buttonStyle(.iconAction)
                        .controlSize(.small)
                        .hoverHint("Pick from Higgsfield uploads")
                }
                if form.canAddReferences {
                    PasteLinkButton(action: onPasteLink)
                        .disabled(linkDownload != nil)
                }
                if let generation, form.canAddReferences {
                    Button("Generate…", systemImage: "wand.and.stars", action: generation.onOpen)
                        .buttonStyle(.iconAction)
                        .controlSize(.small)
                        .disabled(generation.disabledReason != nil)
                        .hoverHint(
                            generation.disabledReason ?? String(localized: "Generate reference images"))
                }
            }
            if let reason = generation?.disabledReason, form.canAddReferences {
                Text(String(localized: "Generate…: \(reason)"))
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }
            if let linkDownload {
                LinkDownloadRow(download: linkDownload, onCancel: onCancelLink)
            }
            if form.references.isEmpty {
                DropButton(title: "Add images", detail: form.mode.referencesHint, systemImage: "photo") {
                    onPick()
                }
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.small) {
                    ForEach(Array(form.references.enumerated()), id: \.element.fileURL) { index, image in
                        ReferenceTile(
                            reference: image, number: index + 1, canMoveLeft: index > 0,
                            canMoveRight: index < form.references.count - 1,
                            onMove: { form.moveReference(at: index, to: index + $0) },
                            onRemove: { form.removeReference(at: index) })
                    }
                    if form.canAddReferences {
                        addSlot
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            form.addReferences(Self.references(Self.images(urls))) > 0
        }
    }

    private var addSlot: some View {
        Button {
            onPick()
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .well(radius: Theme.Radius.small)
        .hoverHint("Add images")
        .accessibilityLabel("Add images")
    }

    static func images(_ urls: [URL]) -> [URL] {
        urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    /// A bookmark can only be made while access is held; the tiles and the job reopen the file through it.
    static func references(_ urls: [URL]) -> [LocalImage] {
        urls.map { url in
            withScopedAccess(to: url, bookmark: nil) { _ in
                LocalImage(fileURL: url, bookmark: AppEnvironment.bookmark(for: url))
            }
        }
    }
}

/// What References needs for Generate…: why it is off, and how to open it.
struct ReferenceGeneration {
    /// Shown under the title, with the button off; `nil` when Generate… can open.
    var disabledReason: String?
    let onOpen: () -> Void
}

/// Seedance's start and end frames: two optional slots above the references, each filled by drop or the file picker.
/// Filling one makes the clip from the frames (`CreateForm.usesFrames`).
struct FramesSection: View {
    @Binding var form: CreateForm
    /// Why this connection can't send frames; the slots are disabled with it as their help.
    let unavailableReason: String?
    let onPick: (FrameSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Frames", detail: String(localized: "Optional"))
            HStack(spacing: Theme.Spacing.small) {
                ForEach(FrameSlot.allCases, id: \.self) { slot in
                    FrameSlotTile(
                        slot: slot, image: form.frame(slot), onPick: { onPick(slot) },
                        onRemove: { form.setFrame(nil, for: slot) }
                    )
                    .dropDestination(for: URL.self) { urls, _ in
                        guard unavailableReason == nil, let url = ReferencesSection.images(urls).first else {
                            return false
                        }
                        form.setFrame(ReferencesSection.references([url]).first, for: slot)
                        return true
                    }
                }
            }
        }
        .disabled(unavailableReason != nil)
        .hoverHint(unavailableReason.map { Text($0) } ?? Text("First and last frame"))
    }
}

private struct FrameSlotTile: View {
    let slot: FrameSlot
    let image: LocalImage?
    let onPick: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Group {
            if let image {
                ReferenceThumb(reference: image)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .overlay(alignment: .topTrailing) {
                        TileButton(systemImage: "xmark", help: String(localized: "Remove"), action: onRemove)
                    }
                    .overlay(alignment: .bottomLeading) {
                        MediaTag(text: slot.title)
                            .padding(3)
                    }
            } else {
                Button(action: onPick) {
                    VStack(spacing: 4) {
                        Image(systemName: slot == .start ? "arrow.right.to.line" : "arrow.left.to.line")
                            .foregroundStyle(Theme.accent)
                        Text(slot.title)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .well(radius: Theme.Radius.small)
                .accessibilityLabel(slot.title)
            }
        }
    }
}

private struct ReferenceTile: View {
    let reference: LocalImage
    /// How the prompt names it: "Image 1" is the first.
    let number: Int
    let canMoveLeft: Bool
    let canMoveRight: Bool
    /// -1 moves left, 1 moves right.
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Theme.well
            .frame(height: 72)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(alignment: .topTrailing) {
                TileButton(systemImage: "xmark", help: "Remove", action: onRemove)
            }
            .overlay(alignment: .topLeading) {
                MediaTag(text: "\(number)")
                    .padding(3)
                    .hoverHint("Image \(number) in the prompt")
            }
            .overlay(alignment: .bottom) {
                HStack {
                    TileButton(systemImage: "chevron.left", help: "Move left") { onMove(-1) }
                        .disabled(!canMoveLeft)
                    Spacer()
                    TileButton(systemImage: "chevron.right", help: "Move right") { onMove(1) }
                        .disabled(!canMoveRight)
                }
            }
            .task(id: reference) {
                image = await ReferenceThumb.image(for: reference)
            }
    }
}

/// A small lime icon button on a scrim, for actions drawn over an image. `help` is also its VoiceOver label.
struct TileButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(isEnabled ? Theme.accent : Theme.faint)
                .frame(width: 18, height: 18)
                .background(Theme.scrim, in: Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(3)
        .hoverHint(help)
        .accessibilityLabel(help)
    }
}

/// A motion transfer or object swap batch: one row per character, each a set of reference images.
/// Picked or dropped images become one new character.
struct CharacterSetsSection: View {
    @Binding var form: CreateForm
    let onPick: () -> Void
    /// Images dropped on the section, for one new character.
    let onDrop: ([URL]) -> Void
    var saving: CharacterSaving?

    /// The set whose name Save to Higgsfield… asks for.
    @State private var naming: Int?
    @State private var name = ""
    /// Sets being saved, by their files.
    @State private var inFlight: Set<[URL]> = []
    @State private var failure: UserMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Characters", detail: form.batchCountText)
            ForEach(Array(form.characterSets.enumerated()), id: \.offset) { index, images in
                CharacterRow(
                    index: index, images: images, save: saveState(of: index, images: images),
                    onSave: {
                        name = String(localized: "Character \(index + 1)")
                        naming = index
                    }
                ) { form.removeCharacterSet(at: index) }
            }
            if let notice = form.batchCapNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            } else {
                DropButton(
                    title: "Add a character", detail: "1–8 images of one character", systemImage: "person.crop.square"
                ) {
                    onPick()
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let images = ReferencesSection.images(urls)
            guard !images.isEmpty else { return false }
            onDrop(images)
            return true
        }
        .alert(SavedElement.saveTitle, isPresented: Binding(isPresenting: $naming), presenting: naming) { index in
            TextField("Name", text: $name)
            Button("Save") { save(index) }
            Button("Cancel", role: .cancel) {}
        } message: { index in
            Text(SavedElement.saveExplanation(imageCount: imageCount(of: index)))
        }
        .alert(failure?.title ?? "", isPresented: Binding(isPresenting: $failure), presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private func imageCount(of index: Int) -> Int {
        form.characterSets.indices.contains(index) ? form.characterSets[index].count : 0
    }

    private func saveState(of index: Int, images: [LocalImage]) -> CharacterRow.SaveState {
        guard let saving else { return .hidden }
        if form.savedElement(ofCharacterSet: index, owner: saving.owner) != nil { return .saved }
        return inFlight.contains(images.map(\.fileURL)) ? .saving : .available
    }

    private func save(_ index: Int) {
        guard let saving, form.characterSets.indices.contains(index) else { return }
        let images = form.characterSets[index]
        let key = images.map(\.fileURL)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let name = name
        Task {
            failure = await saving.save(images, name)
            inFlight.remove(key)
        }
    }
}

private struct CharacterRow: View {
    /// Where the set stands with Save to Higgsfield….
    enum SaveState {
        /// No account connection that publishes elements.
        case hidden
        case available
        case saving
        case saved
    }

    let index: Int
    let images: [LocalImage]
    let save: SaveState
    let onSave: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Character \(index + 1)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(images.count) images")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
                if save == .saved {
                    Label(SavedElement.savedTitle, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
            .frame(width: 92, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(images.prefix(4), id: \.fileURL) { image in
                    ReferenceThumb(reference: image)
                        .frame(width: 40, height: 40)
                }
            }
            Spacer(minLength: 0)
            switch save {
            case .hidden, .saved:
                EmptyView()
            case .saving:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving to Higgsfield")
            case .available:
                Menu {
                    Button(SavedElement.saveTitle, action: onSave)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.accent)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointerCursor()
                .hoverHint("More")
                .accessibilityLabel("More for character \(index + 1)")
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .hoverHint("Remove character")
            .accessibilityLabel("Remove character \(index + 1)")
        }
        .padding(Theme.Spacing.small)
        .well()
    }
}
