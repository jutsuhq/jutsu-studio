import AppKit
import Presentation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "DesignSystem")

/// Design tokens. Dark only: the windows force `.preferredColorScheme(.dark)`.
///
/// Color roles: lime `accent` is for everything clickable; the violet `signature` gradient is for the app
/// doing its trick (brand mark, render progress, the done glow) and never goes on a control.
enum Theme {
    // MARK: Colors

    static let background = Color(rgb: 0x060607)
    static let text = Color.white
    /// Secondary text. 7.3:1 on `background`.
    static let muted = Color.white.opacity(0.6)
    /// Labels, meta lines and hints. 0.48 instead of the mock's 0.38 to reach AA: 5.0:1 on `background`.
    static let faint = Color.white.opacity(0.48)
    static let stroke = Color.white.opacity(0.09)
    /// Inset areas: empty states, inputs.
    static let well = Color.white.opacity(0.04)
    /// Raised surfaces: job rows and onboarding cards (the mock's `.glass.dim`).
    static let card = Color.white.opacity(0.06)
    /// Pills and secondary buttons (the mock's `.glass`).
    static let glass = Color.white.opacity(0.08)
    static let glassHover = Color.white.opacity(0.11)
    static let glassPressed = Color.white.opacity(0.14)
    static let glassStroke = Color.white.opacity(0.2)
    /// The active sidebar row.
    static let selection = Color.white.opacity(0.1)
    /// Progress tracks.
    static let track = Color.white.opacity(0.08)
    /// Behind tags drawn on top of video frames.
    static let scrim = Color.black.opacity(0.55)
    /// Lime `#D4FF2A`, read from `AccentColor.colorset` by name. `Color.accentColor` would follow the user's
    /// system accent instead (blue unless it's set to Multicolor), so the windows also `.tint` with this.
    static let accent = Color("AccentColor")
    static let accentGlow = accent.opacity(0.28)
    /// Text and icons on `accent`. 17.1:1.
    static let ink = Color(rgb: 0x0A0A0A)
    /// The price chip inside a primary button.
    static let inkWash = Color(rgb: 0x0A0A0A).opacity(0.12)
    static let danger = Color(rgb: 0xFF5D5D)
    static let warning = Color(rgb: 0xFFB547)
    static let info = Color(rgb: 0x8AB4FF)

    /// Violet → fuchsia → pink. Brand and "magic" moments only, see the type comment.
    static var signature: Gradient {
        Gradient(colors: [signatureViolet, signatureFuchsia, signaturePink])
    }
    static let signatureViolet = Color(rgb: 0x8B5CF6)
    static let signatureFuchsia = Color(rgb: 0xD946EF)
    static let signaturePink = Color(rgb: 0xF472B6)

    // MARK: Layout

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        /// Page padding, the mock's `.page`.
        static let page: CGFloat = 28
        /// Above the page header: puts the title on the same line as the sidebar brand mark.
        static let pageTop: CGFloat = 12
    }

    enum Radius {
        /// Thumbnails and the brand mark.
        static let small: CGFloat = 8
        /// Sidebar rows.
        static let row: CGFloat = 9
        /// Inputs, wells, media in rows.
        static let field: CGFloat = 12
        static let media: CGFloat = 14
        /// Job rows, onboarding and settings cards.
        static let card: CGFloat = 18
    }

    // MARK: Type

    /// PostScript name of the bundled Barlow Condensed ExtraBold (800), registered by
    /// `ATSApplicationFontsPath` in Info.plist.
    static let displayFontName = "BarlowCondensed-ExtraBold"

    /// SwiftUI silently falls back to the system font for an unknown name; this makes a missing font visible.
    @MainActor
    static func verifyBundledFonts() {
        let name = displayFontName
        if NSFont(name: name, size: 12) == nil {
            logger.error("Display font \(name, privacy: .public) is not registered")
        }
    }
}

extension Color {
    /// `0xRRGGBB` in sRGB.
    init(rgb: UInt32) {
        self.init(
            .sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}

extension Font {
    /// Barlow Condensed ExtraBold for page titles and other display text; body text stays the system font.
    static func display(_ size: CGFloat) -> Font {
        .custom(Theme.displayFontName, size: size)
    }
}

extension ShapeStyle where Self == LinearGradient {
    /// The signature gradient, left to right. Never on a control.
    static var signature: LinearGradient {
        LinearGradient(gradient: Theme.signature, startPoint: .leading, endPoint: .trailing)
    }
}

extension JobRowModel.ColorRole {
    var color: Color {
        switch self {
        case .accent: Theme.accent
        case .info: Theme.info
        case .warning: Theme.warning
        case .danger: Theme.danger
        case .faint: Theme.faint
        }
    }
}
