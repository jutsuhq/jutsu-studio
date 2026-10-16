import Presentation
import SwiftUI

/// The plan and the credits left, above Settings in the sidebar. Opens Settings, where the connection is.
struct AccountPlateView: View {
    let plate: AccountPlate
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    PlanBadge(title: plate.badge, tier: plate.tier, symbol: plate.isAPIKey ? "key.fill" : nil)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isHovered ? Theme.muted : Theme.faint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(plate.amount)
                            .font(.display(plate.isAPIKey ? 22 : 30))
                            .monospacedDigit()
                            .foregroundStyle(plate.warning == nil ? Theme.text : Theme.warning)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(plate.unit)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    if let warning = plate.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.warning)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { background }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [plate.tier.edge.opacity(isHovered ? 0.7 : 0.5), plate.tier.edge.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            }
            .shadow(color: plate.tier.glow, radius: 14, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .hoverHint(plate.warning == nil ? "Your Higgsfield plan · open Settings" : "Top up your plan on higgsfield.ai")
        .accessibilityLabel(plate.accessibilityLabel)
        .accessibilityHint("Opens Settings")
    }

    /// The card, lit from the top corner in the plan's color.
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous)
        return shape.fill(isHovered ? Theme.glass : Theme.card)
            .overlay {
                RadialGradient(
                    colors: [plate.tier.edge.opacity(0.24), .clear], center: .topLeading, startRadius: 0,
                    endRadius: 170)
            }
            .clipShape(shape)
    }
}

/// A plan's name in a capsule dressed for its tier: plain for free, colored for paid plans, metal for the top
/// ones, and the signature gradient with a passing shine for the highest.
struct PlanBadge: View {
    let title: String
    let tier: PlanTier?
    /// Instead of the tier's symbol.
    var symbol: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shine: CGFloat = -1

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol ?? tier.symbol)
                .font(.system(size: 9, weight: .black))
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .kerning(0.8)
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background { fill }
        .overlay { Capsule().strokeBorder(stroke, lineWidth: 0.8) }
        .overlay { if tier.shines { shineOverlay } }
        .clipShape(Capsule())
        .onAppear {
            guard tier.shines, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).delay(1).repeatForever(autoreverses: false)) { shine = 2 }
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(colors: tier.colors, startPoint: .leading, endPoint: .trailing)
    }

    private var foreground: AnyShapeStyle {
        tier == .elite ? AnyShapeStyle(Color.white) : AnyShapeStyle(gradient)
    }

    @ViewBuilder private var fill: some View {
        if tier == .elite {
            Capsule().fill(gradient)
        } else {
            Capsule().fill(gradient.opacity(tier == nil || tier == .free ? 0.1 : 0.16))
        }
    }

    private var stroke: AnyShapeStyle {
        tier == .elite ? AnyShapeStyle(Color.white.opacity(0.35)) : AnyShapeStyle(gradient.opacity(0.55))
    }

    /// A soft band of light that sweeps across now and then.
    private var shineOverlay: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, .white.opacity(tier == .elite ? 0.45 : 0.35), .clear], startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.45)
            .rotationEffect(.degrees(18))
            .offset(x: shine * proxy.size.width)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

extension Optional where Wrapped == PlanTier {
    /// Left to right across the badge.
    var colors: [Color] {
        switch self {
        case nil, .free?: [Color.white.opacity(0.75), Color.white.opacity(0.5)]
        case .starter?: [Color(rgb: 0x9CC2FF), Color(rgb: 0x5B8CFF)]
        case .pro?: [Color(rgb: 0x6EF3DC), Color(rgb: 0x22C3EE)]
        case .premium?: [Color(rgb: 0xFFE8A3), Color(rgb: 0xF5B83D), Color(rgb: 0xE08A1E)]
        case .elite?: [Theme.signatureViolet, Theme.signatureFuchsia, Theme.signaturePink]
        }
    }

    /// The card's edge and corner light.
    var edge: Color {
        switch self {
        case nil, .free?: Color.white.opacity(0.6)
        case .elite?: Theme.signatureFuchsia
        default: colors[colors.count / 2]
        }
    }

    var glow: Color {
        switch self {
        case .premium?: Color(rgb: 0xF5B83D).opacity(0.14)
        case .elite?: Theme.signatureFuchsia.opacity(0.22)
        default: .clear
        }
    }

    var symbol: String {
        switch self {
        case nil: "person.crop.circle"
        case .free?: "circle.dashed"
        case .starter?: "bolt.fill"
        case .pro?: "star.fill"
        case .premium?: "crown.fill"
        case .elite?: "sparkles"
        }
    }

    var shines: Bool { self == .premium || self == .elite }
}
