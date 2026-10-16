import ImageIO
import Presentation
import SwiftUI

/// Two images side by side at the same zoom: one state drives both panes, so they stay in step. Esc goes back.
/// A variant group keeps one variant on the left while ↑ and ↓ step the right side through the others.
struct ImageCompareView: View {
    let close: () -> Void
    @State private var pair: ImageComparePair?
    @State private var variants: VariantCompare?
    @State private var state = ImageCompareState()

    init(pair: ImageComparePair, close: @escaping () -> Void) {
        _pair = State(initialValue: pair)
        self.close = close
    }

    init(variants: VariantCompare, close: @escaping () -> Void) {
        _variants = State(initialValue: variants)
        self.close = close
    }

    private var shown: ImageComparePair? { variants?.pair ?? pair }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            topBar
            if let shown {
                HStack(spacing: Theme.Spacing.medium) {
                    ImageComparePane(image: shown.left, state: $state)
                    ImageComparePane(image: shown.right, state: $state)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(alignment: .top) {
                    title(shown.left)
                    Spacer(minLength: Theme.Spacing.large)
                    title(shown.right)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.pageTop)
        .padding(.bottom, Theme.Spacing.page)
    }

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("Back", systemImage: "chevron.left", action: close)
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
                .hoverHint("Back (Esc)")
            Text("Compare")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.leading, Theme.Spacing.small)
            Spacer(minLength: Theme.Spacing.small)
            if let variants {
                variantPager(variants)
            }
            Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { state.showFit() }
                .buttonStyle(.iconAction)
                .hoverHint("Fit to pane")
                .disabled(state.fitsPane && state.zoom == 1)
            Button("Actual Size", systemImage: "1.magnifyingglass") { state.showActualSize() }
                .buttonStyle(.iconAction)
                .hoverHint("Show at 100%")
                .disabled(!state.fitsPane && state.zoom == 1)
            Slider(
                value: Binding(get: { state.zoom }, set: { state.setZoom($0) }),
                in: ImageCompareState.minZoom...ImageCompareState.maxZoom
            )
            .frame(width: 140)
            .hoverHint("Zoom")
            Button("Swap Sides", systemImage: "arrow.left.arrow.right", action: swap)
                .buttonStyle(.iconAction)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .hoverHint("Swap sides (← →)")
                .background {
                    Button("Swap Sides", action: swap)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }

    private func swap() {
        if variants != nil {
            variants?.swap()
        } else {
            pair?.swap()
        }
    }

    /// "Variant 2 of 4" with ↑ and ↓ to step the right side through the group.
    private func variantPager(_ variants: VariantCompare) -> some View {
        HStack(spacing: 4) {
            Button("Previous Variant", systemImage: "chevron.up") { self.variants?.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .hoverHint("Previous variant (↑)")
            Text(variants.position)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
            Button("Next Variant", systemImage: "chevron.down") { self.variants?.step(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .hoverHint("Next variant (↓)")
        }
        .buttonStyle(.iconAction)
        .padding(.trailing, Theme.Spacing.medium)
    }

    private func title(_ image: CompareImage) -> some View {
        Text(image.prompt.isEmpty ? image.fileURL.lastPathComponent : image.prompt)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }
}

/// One pane of the image compare: the picture at the shared zoom, panned with the shared offset. Dragging pans
/// both panes; pinching zooms both. Fit shows the whole image; Actual Size shows one image pixel per point.
private struct ImageComparePane: View {
    let image: CompareImage
    @Binding var state: ImageCompareState
    @State private var picture: CGImage?
    @State private var imageSize = CGSize(width: 1, height: 1)
    @State private var paneSize = CGSize(width: 1, height: 1)
    @State private var lastDrag: CGSize?
    @State private var lastMagnification: Double?

    var body: some View {
        GeometryReader { proxy in
            Theme.well
                .overlay {
                    if let picture {
                        Image(decorative: picture, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: displaySize.width, height: displaySize.height)
                            .offset(x: state.offsetX, y: state.offsetY)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            // The translation runs from the press: only the step since the last event pans.
                            let last = lastDrag ?? .zero
                            state.pan(
                                byX: drag.translation.width - last.width,
                                y: drag.translation.height - last.height)
                            lastDrag = drag.translation
                        }
                        .onEnded { _ in lastDrag = nil }
                        .simultaneously(
                            with: MagnifyGesture()
                                .onChanged { value in
                                    let last = lastMagnification ?? 1
                                    state.setZoom(state.zoom * value.magnification / last)
                                    lastMagnification = value.magnification
                                }
                                .onEnded { _ in lastMagnification = nil })
                )
                .onAppear {
                    paneSize = proxy.size
                }
                .onChange(of: proxy.size) { _, size in
                    paneSize = size
                }
        }
        .task(id: image.fileURL) {
            let loaded = await Self.load(image.fileURL)
            picture = loaded
            if let loaded {
                imageSize = CGSize(width: loaded.width, height: loaded.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image.prompt.isEmpty ? image.fileURL.lastPathComponent : image.prompt)
    }

    /// What the pane draws: actual pixels magnified, or the fitted image magnified, at the shared zoom — so zoom
    /// 1 in Actual Size is 1:1, whatever the pane holds.
    private var displaySize: CGSize {
        let scale = state.displayScale(
            fitScale: ImageCompareState.fitScale(
                imageWidth: Double(imageSize.width), imageHeight: Double(imageSize.height),
                paneWidth: Double(paneSize.width), paneHeight: Double(paneSize.height)))
        return CGSize(width: imageSize.width * CGFloat(scale), height: imageSize.height * CGFloat(scale))
    }

    private static func load(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
