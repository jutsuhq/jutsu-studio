import Presentation
import SwiftUI

/// Two library results on one clock, side by side or under a divider.
/// ← and → swap the sides, Space plays, Escape goes back.
struct LibraryCompare: View {
    let close: () -> Void
    @State private var pair: ComparePair
    @State private var layout = CompareLayout.sideBySide

    init(pair: ComparePair, close: @escaping () -> Void) {
        _pair = State(initialValue: pair)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            topBar
            ComparePlayer(
                tracks: pair.tracks, layout: layout, aspect: CGFloat(pair.left.aspectRatio ?? 16 / 9),
                nudgesWithArrows: false
            )
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
            HStack(alignment: .top) {
                title(pair.left)
                Spacer(minLength: Theme.Spacing.large)
                title(pair.right)
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
            SegmentedControl(selection: $layout) { $0.title }
                .fixedSize()
            Button("Swap Sides", systemImage: "arrow.left.arrow.right") { pair.swap() }
                .buttonStyle(.iconAction)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .hoverHint("Swap sides (← →)")
                .background {
                    // A second key for the same action; a hidden button's shortcut wouldn't fire.
                    Button("Swap Sides") { pair.swap() }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }

    private func title(_ item: LibraryItemModel) -> some View {
        Text(item.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }
}
