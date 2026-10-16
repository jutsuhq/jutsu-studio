import JutsuCore
import Presentation
import SwiftUI

/// The account's reference elements, as a grid of named thumbnails. Picking one adds its images as references; when
/// it has more than fit, the user picks which ones first.
struct ElementsPicker: View {
    let model: AccountElementsModel
    /// How many more references the form takes.
    let limit: Int
    let onAdd: ([LocalImage]) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// The element whose images are being picked, when it has more than fit.
    @State private var choosing: AccountElement?
    @State private var picked: [Int] = []
    @State private var adding: String?
    @State private var failure: String?
    /// The download `add` started: closing the sheet cancels it, so a Cancel adds nothing.
    @State private var downloading: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: Theme.Spacing.small)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
                .onDisappear { downloading?.cancel() }
            if let reason = model.unavailableReason {
                EmptyState(systemImage: "clock", title: reason, detail: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let choosing {
                imageChooser(choosing)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.medium) {
                        LazyVGrid(columns: columns, spacing: Theme.Spacing.small) {
                            ForEach(model.current) { tile($0) }
                        }
                        footer
                    }
                }
                .frame(maxHeight: .infinity)
            }
            actions
        }
        .task { await model.loadIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(choosing?.name ?? String(localized: "Elements"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(
                    choosing == nil
                        ? String(localized: "Pick one to add its images as references, up to \(limit).")
                        : String(localized: "It has more images than fit. Pick up to \(limit).")
                )
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: Theme.Spacing.small)
            if choosing == nil, model.unavailableReason == nil {
                FilterMenu(
                    title: String(localized: "Category"),
                    selection: Binding(get: { model.category }, set: { model.category = $0 }),
                    options: [(nil, String(localized: "All categories"))]
                        + ElementCategory.allCases.map { (Optional($0), $0.title) })
            }
        }
    }

    private func tile(_ element: AccountElement) -> some View {
        Button {
            pick(element)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Theme.well
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { RemoteThumbnail(url: element.thumbnailURL, maxPixelSize: 320) }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 1)
                    }
                    .overlay {
                        if adding == element.id { ProgressView().controlSize(.small) }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let tag = element.category?.title {
                            MediaTag(text: tag).padding(4)
                        }
                    }
                Text(element.name.isEmpty ? String(localized: "Untitled") : element.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(adding != nil || limit <= 0)
        .accessibilityLabel(element.name)
    }

    @ViewBuilder private var footer: some View {
        if model.failure != nil || model.hasMore {
            PagedFeedFooter(failure: model.failure, hasMore: model.hasMore, count: model.current.count) {
                await model.loadMore()
            }
        } else if model.current.isEmpty {
            EmptyState(
                systemImage: "square.stack.3d.up", title: "No elements yet",
                detail: String(localized: "Characters, environments and props saved on higgsfield.ai appear here.")
            )
            .padding(.top, 60)
        }
    }

    /// The element's images, numbered in the order they are picked.
    private func imageChooser(_ element: AccountElement) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Theme.Spacing.small)]) {
                ForEach(Array(element.images.enumerated()), id: \.offset) { index, image in
                    let number = picked.firstIndex(of: index).map { $0 + 1 }
                    Button {
                        if let position = picked.firstIndex(of: index) {
                            picked.remove(at: position)
                        } else if picked.count < limit {
                            picked.append(index)
                        }
                    } label: {
                        Theme.well
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { RemoteThumbnail(url: image.url, maxPixelSize: 320) }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                    .strokeBorder(
                                        number == nil ? Theme.stroke : Theme.accent, lineWidth: number == nil ? 1 : 2)
                            }
                            .overlay(alignment: .topLeading) {
                                if let number { MediaTag(text: "\(number)").padding(4) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(adding != nil || (number == nil && picked.count >= limit))
                    .accessibilityLabel(
                        number.map { String(localized: "Element image, picked \($0)") }
                            ?? String(localized: "Element image"))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let failure {
                Text(failure)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.small)
            if adding != nil { ProgressView().controlSize(.small) }
            if let choosing {
                Button("Back") {
                    self.choosing = nil
                    picked = []
                }
                .buttonStyle(.secondaryAction)
                Button(picked.count > 1 ? "Add \(picked.count) Images" : "Add Image") {
                    add(picked.map { choosing.images[$0] }, of: choosing)
                }
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || adding != nil)
            } else {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.secondaryAction)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func pick(_ element: AccountElement) {
        adding = element.id
        failure = nil
        Task {
            do {
                let full = try await model.withImages(element)
                switch ElementPick.of(full, limit: limit) {
                case .add(let images):
                    adding = nil
                    add(images, of: full)
                case .choose(let images, let limit):
                    adding = nil
                    picked = Array(images.indices.prefix(limit))
                    choosing = full
                case .unavailable(let reason):
                    adding = nil
                    failure = reason
                }
            } catch {
                adding = nil
                failure = (UserMessage(error, kind: .account) ?? Self.loadFailure).title
            }
        }
    }

    /// Downloads `images` once each and adds them in order; the sheet closes when they're added.
    private func add(_ images: [ElementImage], of element: AccountElement) {
        adding = element.id
        failure = nil
        downloading = Task {
            defer { adding = nil }
            var references: [LocalImage] = []
            do {
                for image in images {
                    let index = element.images.firstIndex(of: image) ?? references.count
                    references.append(try await environment.downloadElementImage(image, at: index, of: element))
                }
            } catch {
                failure = (UserMessage(error, kind: .account) ?? Self.downloadFailure).title
                return
            }
            guard !Task.isCancelled else { return }
            onAdd(references)
            dismiss()
        }
    }

    private static let loadFailure = UserMessage(
        title: String(localized: "Can't open this element"), message: String(localized: "Try again in a moment."))
    private static let downloadFailure = UserMessage(
        title: String(localized: "Can't download the images"), message: String(localized: "Try again in a moment."))
}
