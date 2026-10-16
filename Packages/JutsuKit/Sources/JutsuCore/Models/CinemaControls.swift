import Foundation

/// One of Cinema Studio 4.0's creative controls, by its field in the REST body (`higgsfield/cinema-studio/4.0`). A
/// job sets it to one of the schema's values or leaves it out, and the director picks it then: the schema takes no
/// "auto". The account's `generate_video` names these by IDs its catalog doesn't list, so only an API key sends them.
public enum CinemaControl: String, Sendable, Hashable, CaseIterable {
    case cameraModel = "camera_model"
    case cameraLens = "camera_lens"
    case cameraAperture = "camera_aperture"
    case cameraMovement = "camera_movement"
    case genre
    case era
    case light
    case pacing
    case colorPalette = "color_palette"

    /// The schema's values (docs.higgsfield.ai, 2026-10-15). The camera, lens and aperture go from the cleanest to
    /// the most stylized; the movements and palettes by name.
    public var options: [String] {
        switch self {
        case .cameraModel: ["modern", "35mm-film", "8mm-film", "dv-camcorder"]
        case .cameraLens: ["clean-sharp", "anamorphic", "vintage-anamorphic", "warm-vintage", "halation-vintage"]
        case .cameraAperture: ["f14-wide-open", "f4-moderate", "f11-deep-focus"]
        case .cameraMovement: Self.movements
        case .genre: ["action", "comedy", "drama", "epic", "horror", "noir"]
        case .era: ["1960s", "1980s", "1990s", "2000s", "2020s"]
        case .light: ["window", "practicals", "soft-cross", "overhead-fall", "contre-jour", "silhouette"]
        case .pacing: ["calm", "dynamic", "chaotic", "single-shot"]
        case .colorPalette: Self.palettes
        }
    }

    private static let movements = [
        "aerial-pullback", "arc-left", "arc-right", "bullet-time", "crane-down", "crane-up", "crush-zoom", "dolly-in",
        "dolly-out", "dolly-zoom", "drone-orbit", "handheld", "helicopter-shot", "pan-left", "pan-right",
        "pedestal-down", "pedestal-up", "pov", "rack-focus", "robot-arm", "side-tracking", "slider-left",
        "slider-right", "slow-zoom-in", "slow-zoom-out", "snorricam", "static-shot", "tilt-down", "tilt-up",
        "tracking", "truck-left", "truck-right", "whip-pan",
    ]

    private static let palettes = [
        "a-dream-in-color", "a-hotel-for-one", "after-dark", "amber-wasteland", "back-row-kissing-seats",
        "bioluminescent-night", "breakfast-on-schedule", "bubblegum-boulevard", "crimson-vigi",
        "dont-turn-it-off-im-watching", "everyone-speaks-in-whispers", "favela-gold", "field-post", "gasoline-sunset",
        "ghost-in-the-code", "glossy-flesh", "highway-standoff", "home-is-the-next-gas-station", "industrial-fog",
        "mirage-at-noon", "neon-rain-at-midnight", "oil-ochre", "on-the-other-side-of-the-porthole", "overtime",
        "pink-velvet", "playtime", "runaway-summer", "stairs-go-up", "static-noon", "the-butterfly", "the-circus",
        "the-crimson-ballet", "the-earth-keeps-things-reluctantly", "the-emerald-ambush", "the-faded-fresco",
        "the-grey-channel", "the-ground", "the-investigation", "the-iron-borough", "the-morning-after-rain",
        "the-mountain-convent", "the-neighbors-saw-everything", "the-silk-curtain-falls", "the-way-home-is-longer",
        "tropic-fever-dream", "turquoise-mirage", "twilight-fable", "two-days-to-the-horizon", "wallpaper-romance",
        "yellow-room",
    ]

    /// "Camera", "Lens" and so on: the `cinemaStudio4.<field>` key in `Models.xcstrings`.
    public var title: String {
        let fallback =
            switch self {
            case .cameraModel: "Camera"
            case .cameraLens: "Lens"
            case .cameraAperture: "Aperture"
            case .cameraMovement: "Movement"
            case .genre: "Genre"
            case .era: "Era"
            case .light: "Lighting"
            case .pacing: "Pacing"
            case .colorPalette: "Color palette"
            }
        return Self.localized(rawValue, fallback: fallback)
    }

    /// The title of one of `options`: the `cinemaStudio4.<field>.<value>` key in `Models.xcstrings`, which holds
    /// the English; the value with spaces for hyphens stands in for a key it lacks.
    public func title(of option: String) -> String {
        let words = option.replacingOccurrences(of: "-", with: " ")
        return Self.localized("\(rawValue).\(option)", fallback: words.prefix(1).uppercased() + words.dropFirst())
    }

    static func localized(_ key: String, fallback: String) -> String {
        JutsuCoreResources.bundle.localizedString(forKey: "cinemaStudio4.\(key)", value: fallback, table: "Models")
    }
}

/// The creative controls a Cinema Studio job sets (`CinemaControl`); the director picks each one it leaves out.
public struct CinemaControls: Sendable, Hashable {
    private var values: [CinemaControl: String] = [:]

    public init() {}

    public init(_ values: [CinemaControl: String]) {
        for (control, value) in values { self[control] = value }
    }

    /// `nil` leaves the control to the director. A value the control doesn't have (`CinemaControl.options`) clears
    /// it rather than reaching a schema that refuses it.
    public subscript(control: CinemaControl) -> String? {
        get { values[control] }
        set { values[control] = newValue.flatMap { control.options.contains($0) ? $0 : nil } }
    }

    /// How many controls are set.
    public var count: Int { values.count }

    public var isEmpty: Bool { values.isEmpty }

    /// The REST body's fields, by key.
    public var fields: [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }
}

extension CinemaControls: Codable {
    /// Coded as the body's fields. A field or value this version doesn't know is dropped, so a job or a template
    /// stored by another version still reads.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.singleValueContainer().decode([String: String].self)
        for (key, value) in fields {
            guard let control = CinemaControl(rawValue: key) else { continue }
            self[control] = value
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}
