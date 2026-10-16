import JutsuCore
import Presentation
import SwiftUI

/// The empty stage on an account: Higgsfield's Motion Library to start from, or the user's own video.
/// Hovering a clip plays its example; picking one downloads the clip and makes it the source.
struct MotionLibraryBrowser: View {
    @Bindable var model: MotionLibraryModel
    /// The clip being downloaded; the others wait for it.
    let downloadingID: String?
    let onPick: (MotionPreset) -> Void
    let onPickFile: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: Theme.Spacing.medium)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
            shelfPicker
            ScrollView {
                // Lazy, so the footer appears, and loads the next page, only once scrolled to.
                LazyVStack(spacing: Theme.Spacing.medium) {
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.medium) {
                        if model.current.isEmpty && model.failure == nil && model.hasMore {
                            ForEach(0..<10, id: \.self) { _ in
                                SkeletonTile()
                            }
                        }
                        ForEach(model.current) { preset in
                            MotionClipTile(
                                preset: preset, isDownloading: downloadingID == preset.id,
                                onPick: { onPick(preset) }
                            )
                            .disabled(downloadingID != nil)
                        }
                    }
                    footer
                }
            }
            .scrollIndicators(.automatic)
            // Each tab starts at its top, and its grid replaces the last one at once. Animated with the tab
            // switch, the swap kept hover updates and layout passes retriggering each other, and the main
            // thread spun for tens of seconds; either line alone stops it.
            .id(model.shelf)
            .transaction { $0.animation = nil }
            .frame(maxHeight: .infinity)
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .well(radius: Theme.Radius.card)
        .task(id: model.shelf) {
            await model.loadIfNeeded()
        }
    }

    /// The tabs need about 350 pt; a narrower stage gets the same choice as a menu.
    private var shelfPicker: some View {
        let options = MotionShelf.allCases.map { ($0, $0.title) }
        return ViewThatFits(in: .horizontal) {
            SegmentedControl(selection: $model.shelf, options: options)
                .frame(maxWidth: 480)
            FilterMenu(title: String(localized: "Clips"), selection: $model.shelf, options: options)
        }
    }

    /// Side by side when there is room; the button moves under the text in a narrow window.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                headerText
                Spacer(minLength: 0)
                chooseButton
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                headerText
                chooseButton
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start from a clip")
                .font(.display(30))
                .textCase(.uppercase)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("Hover to preview a motion, click to use it.")
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chooseButton: some View {
        Button {
            onPickFile()
        } label: {
            Label("Choose Video…", systemImage: "video.badge.plus")
                .lineLimit(1)
        }
        .buttonStyle(.secondaryAction)
        .fixedSize()
    }

    /// Loads the next page once scrolled into view; says why when a page failed.
    private var footer: some View {
        // The skeleton stands for the first page; the spinner marks the next ones.
        PagedFeedFooter(
            failure: model.failure, hasMore: model.hasMore, count: model.current.count,
            hidesSpinner: model.current.isEmpty
        ) {
            await model.loadMore()
        }
        .padding(.bottom, Theme.Spacing.large)
    }
}

/// A portrait thumbnail that plays the example on hover.
private struct MotionClipTile: View {
    let preset: MotionPreset
    let isDownloading: Bool
    let onPick: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onPick) {
            // The frame comes from the clear shape alone, so a loaded image or video can't stretch the grid.
            Theme.well
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay {
                    RemoteThumbnail(url: preset.thumbnailURL)
                }
                .overlay {
                    if isHovering, !reduceMotion, let preview = preset.previewURL {
                        LoopingVideo(url: preview)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let mode = preset.exampleMode {
                            MediaTag(text: mode.shortTitle)
                        }
                        MediaTag(text: preset.name)
                    }
                    .padding(6)
                }
                .overlay {
                    if isDownloading {
                        ZStack {
                            Theme.scrim
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                // The clip only trims the drawing: a wide thumbnail filling the tile still reaches into the
                // neighbors for the pointer, and the tile drawn later took the hover.
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .card(isHighlighted: isHovering)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .hoverHint("Use this clip as the source video")
        .accessibilityLabel("\(preset.name), use as source")
    }
}

/// A clip's place while the first page loads.
private struct SkeletonTile: View {
    @State private var isDim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            .fill(Theme.well)
            .aspectRatio(9 / 16, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(Theme.well).frame(width: 40, height: 12)
                    Capsule().fill(Theme.well).frame(width: 90, height: 12)
                }
                .padding(8)
            }
            // Scoped to the opacity: an `animation(_:value:)` here also caught the tile's move while the first
            // grid laid out, and repeated that forever, so a tile slid back and forth.
            .animation(.easeInOut(duration: 0.9).repeatForever()) { $0.opacity(isDim ? 0.45 : 1) }
            .onAppear { isDim = !reduceMotion }
            .accessibilityHidden(true)
    }
}
