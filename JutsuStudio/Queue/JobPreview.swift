import AppKit
import JutsuCore
import MediaKit
import Presentation
import SwiftUI

/// What goes in and what comes out of a job: a frame of the source, the reference images and the result,
/// which shimmers in the signature gradient while the job renders. A clip made without a source shows no source.
struct JobPreview: View {
    let job: Job
    let height: CGFloat

    /// The source's shape, or the frame asked for without one, kept within reason so very tall or wide clips
    /// don't crowd the row.
    private var tileWidth: CGFloat {
        let aspect: Double
        if let size = job.spec.source?.pixelSize {
            guard size.height > 0 else { return height * 16 / 9 }
            aspect = Double(size.width) / Double(size.height)
        } else {
            aspect = job.spec.aspectRatio?.widthOverHeight ?? 16 / 9
        }
        return height * min(max(aspect, 0.56), 1.78)
    }

    /// Tags only on tiles wide enough to hold them; narrow portrait tiles read fine without.
    private var showsTags: Bool { tileWidth >= 76 }

    var body: some View {
        HStack(spacing: 8) {
            if let source = job.spec.source {
                FrameTile(url: source.fileURL, bookmark: source.bookmark)
                    .frame(width: tileWidth, height: height)
                    .overlay(alignment: .topLeading) {
                        if showsTags { MediaTag(text: String(localized: "Source")).padding(5) }
                    }
            }
            if !job.spec.references.isEmpty {
                if job.spec.source != nil { connector("plus") }
                ReferenceStack(references: job.spec.references, size: height * 0.56)
            }
            connector("arrow.right")
            ResultTile(job: job, showsTag: showsTags)
                .frame(width: tileWidth, height: height)
        }
    }

    private func connector(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.faint)
    }
}

/// A frame of a video, from the shared thumbnail cache; a plain well until it loads.
struct FrameTile: View {
    let url: URL?
    var bookmark: Data?
    @State private var image: CGImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.well)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
            }
            .task(id: url) {
                guard let url else { return }
                // Picked sources are security-scoped; access lasts until the frame is cached.
                image = await withScopedAccess(to: url, bookmark: bookmark) { access in
                    await ThumbnailCache.shared.image(for: access.url)
                }
            }
    }
}

/// Up to three reference images fanned out, with a count when there are more.
private struct ReferenceStack: View {
    let references: [LocalImage]
    let size: CGFloat

    var body: some View {
        let shown = Array(references.prefix(3))
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, reference in
                ReferenceThumb(reference: reference)
                    .frame(width: size, height: size)
                    .offset(x: CGFloat(index) * size * 0.32)
                    .zIndex(Double(shown.count - index))
            }
        }
        .frame(width: size + CGFloat(max(shown.count - 1, 0)) * size * 0.32, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            if references.count > shown.count {
                MediaTag(text: "+\(references.count - shown.count)").offset(x: 4, y: 4)
            }
        }
    }
}

struct ReferenceThumb: View {
    let reference: LocalImage
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.well)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.background, lineWidth: 2)
            }
            .task(id: reference) {
                image = await Self.image(for: reference)
            }
    }

    /// Long side of a reference tile's image: enough for the largest tile filled at 2× scale.
    static let maxPixelSize = 512

    /// The reference's image at tile size, read under its security scope; `nil` when it can't be read.
    /// Shared with Create's reference tiles. A job from the account's history names its images by their links.
    @MainActor
    static func image(for reference: LocalImage) async -> NSImage? {
        let thumbnail: CGImage?
        if reference.fileURL.isFileURL {
            thumbnail = await withScopedAccess(to: reference.fileURL, bookmark: reference.bookmark) { access in
                await ImageThumbnail.image(at: access.url, maxPixelSize: maxPixelSize)
            }
        } else {
            thumbnail = await RemoteImageCache.shared.image(for: reference.fileURL, maxPixelSize: CGFloat(maxPixelSize))
        }
        return thumbnail.map { NSImage(cgImage: $0, size: .zero) }
    }
}

/// The output: a frame once it is saved, a moving signature shimmer while it renders, or an icon for a
/// job that stopped.
private struct ResultTile: View {
    let job: Job
    let showsTag: Bool

    var body: some View {
        switch job.state {
        case .done:
            FrameTile(url: job.outputFile)
                .overlay(alignment: .topLeading) {
                    if showsTag { MediaTag(text: String(localized: "Result")).padding(5) }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 18, height: 18)
                        .background(Theme.accent, in: Circle())
                        .padding(5)
                }
        case .paused:
            placeholder("pause.fill", tint: Theme.warning)
        case .failed, .rejected:
            placeholder("exclamationmark.triangle", tint: Theme.danger)
        case .canceled:
            placeholder("xmark", tint: Theme.faint)
        default:
            RenderingTile()
        }
    }

    private func placeholder(_ systemImage: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.well)
            .overlay {
                Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
            }
    }
}

/// The signature gradient with a light band sweeping across: the app doing its trick.
private struct RenderingTile: View {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(gradient: Theme.signature, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.55)
            )
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: phase * proxy.size.width)
                }
            }
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
            .accessibilityLabel("Rendering")
    }
}

/// Prepare → Upload → Generate → Save, with the current step lit and its percentage when known.
struct StageStepper: View {
    let stage: JobRowModel.Stage
    /// Beside the current step's title: its progress or time, "42%", "1:05".
    var detail = ""

    var body: some View {
        // Labels on every step when they fit, otherwise only on the current one.
        ViewThatFits(in: .horizontal) {
            steps(labelsOn: { _ in true })
            steps(labelsOn: { $0 == stage })
        }
    }

    private func steps(labelsOn showsLabel: @escaping (JobRowModel.Stage) -> Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(JobRowModel.Stage.allCases, id: \.self) { step in
                if step != .prepare {
                    Capsule()
                        .fill(step.rawValue <= stage.rawValue ? Theme.accent.opacity(0.6) : Theme.stroke)
                        .frame(width: 16, height: 2)
                }
                HStack(spacing: 5) {
                    dot(for: step)
                    if showsLabel(step) {
                        Text(
                            step == stage
                                ? [step.title, detail].filter { !$0.isEmpty }.joined(separator: " ")
                                : step.title
                        )
                        .font(.system(size: 11.5, weight: step == stage ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(
                            step == stage ? Theme.text : (step.rawValue < stage.rawValue ? Theme.muted : Theme.faint)
                        )
                        .lineLimit(1)
                        .fixedSize()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(stage.rawValue + 1) of 4, \(stage.title)")
    }

    @ViewBuilder
    private func dot(for step: JobRowModel.Stage) -> some View {
        if step.rawValue < stage.rawValue {
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .frame(width: 14, height: 14)
                .background(Theme.accent, in: Circle())
        } else if step == stage {
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
                .frame(width: 14, height: 14)
                .overlay { Circle().strokeBorder(Theme.accent, lineWidth: 1.5) }
        } else {
            Circle()
                .strokeBorder(Theme.stroke, lineWidth: 1.5)
                .frame(width: 14, height: 14)
        }
    }
}
