import CoreGraphics
import JutsuCore
import MediaKit
import Presentation
import SwiftUI

/// An image's details: the picture and prompt of the exact version, what it was made from, and every video made from
/// it (`MaterialRelations`). Images have no page of their own, so this sheet is where the grid's Details… and a
/// video's "Made from" lead; a video opens its page, a source image these details.
struct ImageDetailsSheet: View {
    let reference: MaterialReference
    let relations: MaterialRelations
    let openVideo: (UUID) -> Void
    let openImage: (MaterialReference) -> Void
    /// Make Video from the image; `nil` while it can't be opened.
    let makeVideo: (() -> Void)?
    let quickLook: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    private var image: MaterialLink { relations.link(to: reference) }

    var body: some View {
        let image = image
        let usedIn = relations.usedIn(reference.materialID)
        let madeFrom = relations.madeFrom(reference)
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                MaterialPreview(link: image)
                    .frame(width: 160, height: 160)
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text(image.prompt.isEmpty ? String(localized: "No prompt") : image.prompt)
                        .font(.callout)
                        .foregroundStyle(image.prompt.isEmpty ? Theme.faint : Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary(of: image))
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                    if let note = image.availabilityNote {
                        Text(note)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            if !madeFrom.isEmpty {
                MadeFromImages(links: madeFrom, open: openImage)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(title: "Used in", detail: usedIn.isEmpty ? nil : "\(usedIn.count)")
                if usedIn.isEmpty {
                    Text("No video has been made from this image yet.")
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                            ForEach(usedIn) { video in videoRow(video) }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
            HStack(spacing: Theme.Spacing.small) {
                if let file = image.previewURL, file.isFileURL, image.availability != .unavailable {
                    Button("Quick Look", systemImage: "eye") { quickLook(file) }
                        .buttonStyle(.secondaryAction)
                }
                if let makeVideo {
                    Button("Make Video…", systemImage: "film") {
                        dismiss()
                        makeVideo()
                    }
                    .buttonStyle(.secondaryAction)
                }
                Spacer(minLength: Theme.Spacing.small)
                Button("Done") { dismiss() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 480)
        .background(Theme.background)
    }

    /// One video made from the image: a click opens its page, unless it is gone.
    private func videoRow(_ video: MaterialLink) -> some View {
        Button {
            dismiss()
            openVideo(video.reference.materialID)
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                MaterialPreview(link: video)
                    .frame(width: 96, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.prompt.isEmpty ? String(localized: "Video") : video.prompt)
                        .font(.callout)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Text(([video.roleTitle] + [video.availabilityNote].compactMap(\.self)).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(video.availability == .unavailable)
        .hoverHint(video.availability == .unavailable ? "No longer in the library" : "Open video")
    }

    /// "soul · 15 Oct 2026".
    private func summary(of image: MaterialLink) -> String {
        ([relations.version(reference)?.generation?.model].compactMap(\.self).filter { !$0.isEmpty }
            + [image.createdAt?.formatted(date: .abbreviated, time: .omitted)].compactMap(\.self))
            .joined(separator: " · ")
    }
}

/// The images a video was made from, each with its role; a click shows that exact version's details. A source that
/// was removed or can't be found stays, marked unavailable.
struct MadeFromImages: View {
    let links: [MaterialLink]
    let open: (MaterialReference) -> Void

    var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(title: "Made from")
                FlowLayout(spacing: Theme.Spacing.small) {
                    ForEach(links) { link in
                        Button {
                            open(link.reference)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                MaterialPreview(link: link)
                                    .frame(width: 72, height: 72)
                                Text(link.roleTitle)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if let note = link.availabilityNote {
                                    Text(note)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.faint)
                                }
                            }
                            .frame(width: 72, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .hoverHint(link.prompt.isEmpty ? String(localized: "Show this image") : link.prompt)
                    }
                }
            }
        }
    }
}

/// The picture of a linked image or a frame of a linked video; a placeholder when it is unavailable.
struct MaterialPreview: View {
    let link: MaterialLink
    @State private var picture: CGImage?

    var body: some View {
        Theme.well
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
            .opacity(link.availability == .unavailable ? 0.6 : 1)
    }

    @ViewBuilder private var content: some View {
        if link.availability == .unavailable {
            Image(systemName: link.kind == .video ? "questionmark.video" : "externaldrive.badge.questionmark")
                .font(.title3)
                .foregroundStyle(Theme.faint)
        } else if link.kind == .video {
            LibraryThumbnail(url: link.previewURL)
        } else if let url = link.previewURL, !url.isFileURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            Group {
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().scaledToFill()
                }
            }
            .task(id: link.previewURL) {
                guard let url = link.previewURL else { return }
                picture = await ImageThumbnail.image(at: url, maxPixelSize: 320)
            }
        }
    }
}
