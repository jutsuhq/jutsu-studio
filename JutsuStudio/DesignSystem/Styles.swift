import AppKit
import SwiftUI

/// The lime call to action (`.cta.lime`): one per screen, e.g. sign in or render final.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration)
    }
}

/// Everything else clickable (`.btn.glass`). A destructive role turns the label red.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButton(configuration: configuration)
    }
}

/// An inline text action in lime, for links and "use a code instead".
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextLinkButton(configuration: configuration)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryAction: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// A round glass button holding one symbol, for toolbars of small actions.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var iconAction: IconButtonStyle { IconButtonStyle() }
}

extension ButtonStyle where Self == TextLinkButtonStyle {
    static var textLink: TextLinkButtonStyle { TextLinkButtonStyle() }
}

/// Views rather than inline bodies so they can read `isEnabled`.
/// Lime with a glow; brightens on hover. Disabled it drops to a flat glass capsule with faint text
/// rather than see-through lime, which reads as muddy olive on the dark background.
private struct PrimaryButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .heavy))
            .lineLimit(1)
            .foregroundStyle(isEnabled ? Theme.ink : Theme.faint)
            .padding(.horizontal, 18)
            .frame(minHeight: 42)
            .background {
                Capsule()
                    .fill(isEnabled ? Theme.accent : Theme.glass)
                    .brightness(isEnabled && isHovered && !configuration.isPressed ? 0.06 : 0)
            }
            .overlay { if !isEnabled { Capsule().strokeBorder(Theme.stroke, lineWidth: 1) } }
            .shadow(
                color: isEnabled ? Theme.accentGlow.opacity(isHovered ? 1.4 : 1) : .clear,
                radius: isHovered ? 18 : 14, y: 8
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .contentShape(Capsule())
            .pointerCursor()
            .onHover { isHovered = $0 }
            .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
            .motionAnimation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct SecondaryButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(fill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isHovered && isEnabled ? Theme.glassStroke : Theme.stroke, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .contentShape(Capsule())
            .pointerCursor()
            .onHover { isHovered = $0 }
            .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
            .motionAnimation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var fill: Color {
        guard isEnabled else { return Theme.well }
        if configuration.isPressed { return Theme.glassPressed }
        return isHovered ? Theme.glassHover : Theme.glass
    }
}

private struct IconButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.text)
            .frame(width: 34, height: 34)
            .background(fill, in: Circle())
            .overlay { Circle().strokeBorder(isHovered && isEnabled ? Theme.glassStroke : Theme.stroke, lineWidth: 1) }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .contentShape(Circle())
            .pointerCursor()
            .onHover { isHovered = $0 }
            .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
            .motionAnimation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var fill: Color {
        guard isEnabled else { return Theme.well }
        if configuration.isPressed { return Theme.glassPressed }
        return isHovered ? Theme.glassHover : Theme.glass
    }
}

private struct TextLinkButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
            .underline(isHovered)
            .opacity(configuration.isPressed ? 0.7 : (isHovered ? 1 : 0.9))
            .contentShape(Rectangle())
            .pointerCursor()
            .onHover { isHovered = $0 }
    }
}

/// A raised surface (`.glass.dim`): job rows, onboarding cards.
struct CardModifier: ViewModifier {
    var radius = Theme.Radius.card
    var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isHighlighted ? Theme.accent : Theme.stroke, lineWidth: isHighlighted ? 2 : 1)
            }
    }
}

/// An inset area (`--well`): empty states.
struct WellModifier: ViewModifier {
    var radius = Theme.Radius.field

    func body(content: Content) -> some View {
        content
            .background(Theme.well, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
    }
}

extension View {
    func card(radius: CGFloat = Theme.Radius.card, isHighlighted: Bool = false) -> some View {
        modifier(CardModifier(radius: radius, isHighlighted: isHighlighted))
    }

    func well(radius: CGFloat = Theme.Radius.field) -> some View {
        modifier(WellModifier(radius: radius))
    }

    /// A lime ring for custom focusable views; pair with `.focusEffectDisabled()` so the system ring
    /// doesn't draw as well.
    func focusRing(_ isFocused: Bool, radius: CGFloat) -> some View {
        overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Page padding: `page` on the sides and bottom, `pageTop` above the header.
    func pagePadding() -> some View {
        padding(.horizontal, Theme.Spacing.page)
            .padding(.top, Theme.Spacing.pageTop)
            .padding(.bottom, Theme.Spacing.page)
    }

    /// The pointing hand over anything clickable while it is enabled.
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }

    /// A text field drawn as a well with a lime border while focused, instead of the system rounded border
    /// and its accent-colored focus ring.
    func themedField(isFocused: Bool) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(height: 38)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent : Theme.stroke, lineWidth: isFocused ? 1.5 : 1)
            }
            .focusEffectDisabled()
            .motionAnimation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private struct PointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.onHover { isInside in
                if isInside && isEnabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
