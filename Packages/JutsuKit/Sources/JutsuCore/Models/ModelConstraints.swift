import Foundation

/// What the server says one model takes, over the constants in `VideoModel.limits(for:hasSource:)`. Each bound is
/// optional: a missing one keeps the constant, and so does a pair that contradicts itself (a minimum above the
/// maximum). Decoded tolerantly, since it comes from a cache of `models_explore` answers whose shape no export has
/// confirmed yet (issue #37): a field that is missing or of another type is `nil`, never an error.
public struct ModelConstraints: Sendable, Hashable, Codable {
    /// Seconds of source one job takes, or for a clip made without one, the seconds it runs.
    public var minDuration: TimeInterval?
    public var maxDuration: TimeInterval?
    public var minReferenceImages: Int?
    public var maxReferenceImages: Int?

    public init(
        minDuration: TimeInterval? = nil, maxDuration: TimeInterval? = nil, minReferenceImages: Int? = nil,
        maxReferenceImages: Int? = nil
    ) {
        self.minDuration = Self.seconds(minDuration)
        self.maxDuration = Self.seconds(maxDuration)
        self.minReferenceImages = Self.count(minReferenceImages)
        self.maxReferenceImages = Self.count(maxReferenceImages)
    }

    private enum CodingKeys: String, CodingKey {
        case minDuration, maxDuration, minReferenceImages, maxReferenceImages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            minDuration: try? container.decodeIfPresent(Double.self, forKey: .minDuration),
            maxDuration: try? container.decodeIfPresent(Double.self, forKey: .maxDuration),
            minReferenceImages: try? container.decodeIfPresent(Int.self, forKey: .minReferenceImages),
            maxReferenceImages: try? container.decodeIfPresent(Int.self, forKey: .maxReferenceImages))
    }

    /// `limits` with the bounds this has, where they make a range.
    public func applied(to limits: ModeLimits) -> ModeLimits {
        var limits = limits
        let duration = (minDuration ?? limits.duration.lowerBound, maxDuration ?? limits.duration.upperBound)
        if duration.0 <= duration.1 { limits.duration = duration.0...duration.1 }
        let images = (
            minReferenceImages ?? limits.referenceImages.lowerBound,
            maxReferenceImages ?? limits.referenceImages.upperBound
        )
        if images.0 <= images.1 { limits.referenceImages = images.0...images.1 }
        return limits
    }

    /// A length above 0 s and at most an hour, else `nil`: the bound is turned into whole seconds.
    private static func seconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 3600 else { return nil }
        return value
    }

    /// A count of 0 or more, else `nil`.
    private static func count(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

/// The server's constraints of the models the account runs, by model and mode; an empty table (`builtIn`) leaves
/// every limit on its constant. Injected wherever limits are read (`VideoModel.limits(for:hasSource:constraints:)`),
/// so the rules stay pure: the app reads it from a cache, never on a form edit.
public struct ModelConstraintTable: Sendable, Hashable, Codable {
    public struct Entry: Sendable, Hashable, Codable {
        public var model: VideoModel
        public var mode: Mode
        public var constraints: ModelConstraints

        public init(model: VideoModel, mode: Mode, constraints: ModelConstraints) {
            self.model = model
            self.mode = mode
            self.constraints = constraints
        }
    }

    public private(set) var entries: [Entry]

    /// The constants alone.
    public static let builtIn = ModelConstraintTable(entries: [])

    public init(entries: [Entry]) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// An entry of an unknown model or mode, or that can't be read, is dropped; the others are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decodeIfPresent([Lossy<Entry>].self, forKey: .entries) ?? []
        self.init(entries: entries.compactMap(\.value))
    }

    /// The first entry for `model` in `mode`.
    public subscript(model: VideoModel, mode: Mode) -> ModelConstraints? {
        entries.first { $0.model == model && $0.mode == mode }?.constraints
    }

    /// Where these limits differ from the constants, one line per model and mode, for a Debug log that notices
    /// server changes. Empty when they agree.
    public var differencesFromBuiltIn: [String] {
        entries.compactMap { entry in
            let constant = entry.model.limits(for: entry.mode)
            let server = entry.model.limits(for: entry.mode, constraints: self)
            guard constant != server else { return nil }
            return "\(entry.model.rawValue) \(entry.mode.rawValue): duration \(server.duration) "
                + "(built in \(constant.duration)), images \(server.referenceImages) "
                + "(built in \(constant.referenceImages))"
        }
    }
}
