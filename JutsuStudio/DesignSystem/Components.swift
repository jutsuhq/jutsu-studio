import AppKit
import Presentation
import SwiftUI

/// The big uppercase title and a muted line under it (`.head`).
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    /// A literal title, looked up in the string catalog.
    init(title: LocalizedStringResource, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: String(localized: title), subtitle: subtitle, trailing: trailing)
    }

    /// A title that is already localized. Disfavored, as in SwiftUI's `Text`, so a literal picks the catalog.
    @_disfavoredOverload
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        // Trailing controls move under the title when the page is too narrow for both.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
                titles
                Spacer(minLength: 0)
                trailing()
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                titles
                trailing()
            }
        }
        .padding(.bottom, Theme.Spacing.xLarge)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(title)
                .font(.display(40))
                .textCase(.uppercase)
                .foregroundStyle(Theme.text)
            // One line on every screen so the content below starts at the same height everywhere.
            Text(subtitle ?? " ")
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: LocalizedStringResource, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }

    @_disfavoredOverload
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A small uppercase caption above a group, with an optional count or price on the right (`.label`).
struct SectionLabel: View {
    let title: String
    var detail: String?

    /// A literal title, looked up in the string catalog.
    init(title: LocalizedStringResource, detail: String? = nil) {
        self.init(title: String(localized: title), detail: detail)
    }

    /// A title that is already localized. Disfavored, as in SwiftUI's `Text`, so a literal picks the catalog.
    @_disfavoredOverload
    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.8)
                .textCase(.uppercase)
            Spacer(minLength: Theme.Spacing.small)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.faint)
    }
}

/// A status or info capsule with an optional colored dot (`.pill`).
struct Pill: View {
    let text: String
    var dot: Color?
    var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(dot)
                    .symbolEffect(.pulse, isActive: isPulsing && !reduceMotion)
            }
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.glass, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.glassStroke, lineWidth: 0.5) }
    }
}

extension Pill {
    /// A job's status, colored by its role.
    init(status text: String, role: JobRowModel.ColorRole, isPulsing: Bool) {
        self.init(text: text, dot: role.color, isPulsing: isPulsing)
    }
}

/// The price inside a primary button (`.cta .price`); inherits the button's ink.
struct PriceTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.inkWash, in: Capsule())
    }
}

/// A tag drawn on a video frame, e.g. the mode, "Draft" or the duration (`.tag`).
struct MediaTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Theme.scrim, in: Capsule())
    }
}

/// One sidebar destination (`.nav button`): muted until active, then a light fill and a lime icon.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    /// Draws the lime keyboard-focus ring on this row (keyboard navigation in the sidebar, this row selected).
    var isFocused = false
    /// Active jobs; VoiceOver reads it as "Queue, 3 active".
    var badge = 0
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isSelected || isHovered ? Theme.text : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                isSelected ? Theme.selection : (isHovered ? Theme.card : .clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .focusRing(isFocused, radius: Theme.Radius.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel(badge > 0 ? String(localized: "\(title), \(badge) active") : title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The app icon and name at the top of the sidebar (`.brand`). The icon carries the signature gradient.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Jutsu Studio")
                .font(.display(17))
                .kerning(0.3)
                .textCase(.uppercase)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Soft signature light falling from the top of a page, for brand moments such as onboarding.
struct SignatureBackdrop: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Theme.signatureViolet.opacity(0.22), .clear],
                center: UnitPoint(x: 0.35, y: -0.1), startRadius: 0, endRadius: 560)
            RadialGradient(
                colors: [Theme.signaturePink.opacity(0.12), .clear],
                center: UnitPoint(x: 0.75, y: -0.05), startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The app icon large, floating on a signature glow (onboarding hero).
struct GlowingAppIcon: View {
    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .background {
                RadialGradient(
                    colors: [
                        Theme.signatureFuchsia.opacity(0.45), Theme.signatureViolet.opacity(0.22),
                        Theme.signatureViolet.opacity(0),
                    ],
                    center: .center, startRadius: size * 0.2, endRadius: size * 1.1
                )
                .frame(width: size * 2.4, height: size * 2.4)
            }
            .accessibilityHidden(true)
    }
}

/// Progress of a job while it renders: the signature gradient on a thin track (`.track`).
struct RenderProgress: View {
    let value: Double
    /// Filled against a typical time rather than reported progress: drawn faded, and read out as `estimate`.
    var estimate: String?

    var body: some View {
        let fraction = min(max(value, 0), 1)
        Capsule()
            .fill(Theme.track)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(estimate == nil ? AnyShapeStyle(.signature) : AnyShapeStyle(Theme.accent.opacity(0.45)))
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .clipShape(Capsule())
            .accessibilityElement()
            .accessibilityLabel(estimate == nil ? "Progress" : "Estimated time")
            .accessibilityValue(estimate ?? CostText.percent(fraction: fraction))
    }
}

/// A generating job against the typical time of similar past jobs, labelled as an estimate.
struct EstimatedProgress: View {
    let estimate: JobRowModel.TimeEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RenderProgress(value: estimate.fraction, estimate: estimate.label)
            Text("\(estimate.label) · estimate")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(estimate.isOverdue ? Theme.warning : Theme.faint)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .hoverHint(estimate.help)
    }
}

/// A brief signature glow behind a result that has just finished. Starts lit and fades once on appear.
struct FreshGlow: ViewModifier {
    let radius: CGFloat
    @State private var opacity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isFresh: Bool, radius: CGFloat) {
        self.radius = radius
        _opacity = State(initialValue: isFresh ? 0.6 : 0)
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.signature)
                    .blur(radius: 14)
                    .opacity(opacity)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard opacity > 0 else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 2.4).delay(0.4)) { opacity = 0 }
            }
    }
}

extension View {
    func freshGlow(_ isFresh: Bool, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(FreshGlow(isFresh: isFresh, radius: radius))
    }
}

/// An empty section: an icon tile, a line of text and an optional action (`.empty`).
struct EmptyState<Action: View>: View {
    let systemImage: String
    let title: String
    var detail: String?
    @ViewBuilder var action: () -> Action

    /// A literal title, looked up in the string catalog.
    init(
        systemImage: String, title: LocalizedStringResource, detail: String? = nil,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.init(systemImage: systemImage, title: String(localized: title), detail: detail, action: action)
    }

    /// A title that is already localized. Disfavored, as in SwiftUI's `Text`, so a literal picks the catalog.
    @_disfavoredOverload
    init(systemImage: String, title: String, detail: String? = nil, @ViewBuilder action: @escaping () -> Action) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.action = action
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 44, height: 44)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, Theme.Spacing.xSmall)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            action()
                .padding(.top, Theme.Spacing.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, Theme.Spacing.large)
    }
}

extension EmptyState where Action == EmptyView {
    init(systemImage: String, title: LocalizedStringResource, detail: String? = nil) {
        self.init(systemImage: systemImage, title: title, detail: detail) { EmptyView() }
    }

    @_disfavoredOverload
    init(systemImage: String, title: String, detail: String? = nil) {
        self.init(systemImage: systemImage, title: title, detail: detail) { EmptyView() }
    }
}

/// A dashed inset area that turns lime on hover or while files are dragged over it (`.drop`).
struct DropZoneModifier: ViewModifier {
    var isHighlighted = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let lit = isHighlighted || isHovered
        content
            .background(
                lit ? Theme.accent.opacity(0.06) : Theme.well,
                in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(
                        lit ? Theme.accent.opacity(0.7) : Theme.glassStroke,
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            .onHover { isHovered = $0 }
            .motionAnimation(.easeOut(duration: 0.15), value: lit)
    }
}

extension View {
    func dropZone(isHighlighted: Bool = false) -> some View {
        modifier(DropZoneModifier(isHighlighted: isHighlighted))
    }
}
