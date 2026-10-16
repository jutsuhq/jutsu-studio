import JutsuCore
import Presentation
import SwiftUI

/// References › From Higgsfield: the account's uploads and, on an account, its elements and character sheets.
struct HiggsfieldReferencesSheet: View {
    enum Source: Hashable {
        case uploads
        case elements
        case characters
    }

    let uploads: PagedFeed<UploadedFile>
    /// `nil` without a provider that keeps elements: only the uploads are shown.
    let elements: AccountElementsModel?
    /// Whether the connection makes character sheets.
    let offersCharacters: Bool
    /// How many more references the form takes.
    let limit: Int
    let onAdd: ([LocalImage]) -> Void

    @State private var source = Source.uploads

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if sources.count > 1 {
                SegmentedControl(selection: $source, options: sources)
                    .fixedSize()
            }
            switch source {
            case .uploads:
                UploadsPicker(feed: uploads, limit: limit, onAdd: onAdd)
            case .elements:
                if let elements { ElementsPicker(model: elements, limit: limit, onAdd: onAdd) }
            case .characters:
                CharacterSheetsPicker(limit: limit, onAdd: onAdd)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .background(Theme.background)
    }

    private var sources: [(Source, String)] {
        var sources = [(Source.uploads, String(localized: "Uploads"))]
        if elements != nil { sources.append((.elements, String(localized: "Elements"))) }
        if offersCharacters { sources.append((.characters, String(localized: "Characters"))) }
        return sources
    }
}

/// Images the account uploaded to Higgsfield before, to use again as references. Picked images are downloaded
/// once, then added in the order they were picked.
struct UploadsPicker: View {
    let feed: PagedFeed<UploadedFile>
    /// How many more references the form takes.
    let limit: Int
    let onAdd: ([LocalImage]) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []
    @State private var isAdding = false
    @State private var failure: UserMessage?
    /// The download `add` started: closing the sheet cancels it, so a Cancel adds nothing.
    @State private var downloading: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Theme.Spacing.small)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
                .onDisappear { downloading?.cancel() }
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.medium) {
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.small) {
                        ForEach(feed.items) { tile($0) }
                    }
                    footer
                }
            }
            .frame(maxHeight: .infinity)
            actions
        }
        .task {
            // Opened again later, it shows what was uploaded since.
            if feed.hasLoaded { await feed.refresh() } else { await feed.loadIfNeeded() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your uploads on Higgsfield")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Images you uploaded before, newest first. Pick up to \(limit) to use as references.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
        }
    }

    private func tile(_ upload: UploadedFile) -> some View {
        let number = picked.firstIndex(of: upload.id).map { $0 + 1 }
        return Button {
            toggle(upload.id)
        } label: {
            Theme.well
                .aspectRatio(1, contentMode: .fit)
                .overlay { RemoteThumbnail(url: upload.url, maxPixelSize: 320) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(number == nil ? Theme.stroke : Theme.accent, lineWidth: number == nil ? 1 : 2)
                }
                .overlay(alignment: .topLeading) {
                    if let number {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 20, height: 20)
                            .background(Theme.accent, in: Circle())
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isAdding || (number == nil && picked.count >= limit))
        .accessibilityLabel(
            number.map { String(localized: "Uploaded image, picked \($0)") } ?? String(localized: "Uploaded image"))
    }

    /// The next page once scrolled to; a failed page offers a retry, an account with no uploads says so.
    @ViewBuilder private var footer: some View {
        if feed.failure != nil || feed.hasMore {
            PagedFeedFooter(feed)
        } else if feed.items.isEmpty {
            EmptyState(
                systemImage: "photo.on.rectangle", title: "No uploaded images yet",
                detail: String(localized: "Reference images sent from this app or higgsfield.ai appear here.")
            )
            .padding(.top, 60)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let failure {
                Text(failure.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.small)
            if isAdding { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
            Button(picked.count > 1 ? "Add \(picked.count) Images" : "Add Image") { add() }
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || isAdding)
        }
    }

    private func toggle(_ id: String) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else if picked.count < limit {
            picked.append(id)
        }
    }

    private func add() {
        let uploads = picked.compactMap { id in feed.items.first { $0.id == id } }
        isAdding = true
        failure = nil
        downloading = Task {
            defer { isAdding = false }
            var images: [LocalImage] = []
            do {
                for upload in uploads { images.append(try await environment.downloadUpload(upload)) }
            } catch {
                failure =
                    UserMessage(error, kind: .account)
                    ?? UserMessage(
                        title: String(localized: "Can't download the images"),
                        message: String(localized: "Try again in a moment."))
                return
            }
            guard !Task.isCancelled else { return }
            onAdd(images)
            dismiss()
        }
    }
}
