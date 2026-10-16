import Foundation

/// What one video model is, as `models.json` describes it: the modes it serves, its limits, the Create controls it
/// declares and how its jobs reach the server. `VideoModel` reads it by ID.
public struct VideoModelDescriptor: Sendable, Hashable {
    /// A Create control a model shows; any other model hides it.
    public enum Control: String, Sendable, Hashable, CaseIterable {
        /// Draft at a lower resolution.
        case draft
        /// A clip from the prompt and images alone, with its length and frame.
        case clipWithoutSource
        /// A soundtrack made by the model for a clip with a source, instead of the source's.
        case generatedAudio
        /// Seedance's `bitrate_mode`.
        case bitrate
        /// A start and an end frame instead of references, without a source.
        case frames
        /// Standard and Pro instead of a resolution (`KlingQuality`).
        case quality
        /// Which way the character faces (`CharacterOrientation`).
        case characterOrientation
        /// Keeps the source video's background.
        case videoBackground
        /// Cinema Studio 4.0's camera, lens, genre, era and the rest (`CinemaControls`).
        case cinemaControls
    }

    /// The code that encodes a job's body for the REST endpoint and its `generate_video` arguments. A model whose
    /// request has the same fields as one of these reuses it, so most models are a JSON entry only.
    public enum RequestShape: String, Sendable, Hashable, CaseIterable {
        case genjutsu
        case seedance
        case klingMotionControl
        /// Kling O3 from a reference video: the source, the images and the prompt, with the quality as a field.
        case klingVideoReference
        /// Kling O3's Edit: the source changed by the prompt, with the images and the quality as a field; no length,
        /// the output follows the source.
        case klingVideoEdit
        /// Wan's reference-to-video: the source, the images and the prompt, with the length and the resolution, and
        /// the soundtrack for a model that makes one (`generatedAudio`). MiniMax H3 sends the same.
        case wanReference
        /// Cinema Studio 4.0 from a source: the source and the images as references and the prompt, with the length,
        /// the resolution and the soundtrack, and the creative controls the job sets (`CinemaControls`); the director
        /// picks the rest.
        case cinemaStudio
    }

    /// The account's estimate of a job's credits, for when Higgsfield can't quote it yet (a model billed by its
    /// source before the source is uploaded) or the quote failed: `base` plus `perSecond` at the job's resolution
    /// for each billed second, rounded up. A mode priced apart from the model's others has its own in `modes`.
    public struct Credits: Sendable, Hashable {
        public var base: Double
        public var perSecond: [Resolution: Double]
        public var modes: [Mode: Credits]

        public init(base: Double, perSecond: [Resolution: Double], modes: [Mode: Credits] = [:]) {
            self.base = base
            self.perSecond = perSecond
            self.modes = modes
        }

        /// The rates of `mode`: its own when it has them, else the model's.
        public func at(_ mode: Mode) -> Credits {
            modes[mode] ?? self
        }
    }

    public var id: String
    /// The model picker groups by it.
    public var family: String
    public var title: String
    /// One line under the picker.
    public var detail: String
    /// In the order `models.json` lists them.
    public var modes: [Mode]
    /// The resolutions it renders at, in `Resolution`'s order: 480p, 720p and 1080p (`Resolution.standard`) unless
    /// `models.json` lists its own. The picker offers these, and `Pricing` needs a rate for each.
    public var resolutions: [Resolution]
    /// The frames a REST body may name, for a model whose schema takes `aspect_ratio` but not the source's own
    /// frame: the body names the one nearest the source. Empty to leave the field out.
    public var aspectRatios: [AspectRatio]
    /// Over the mode's own (`Mode.limits`); `nil` keeps it.
    public var duration: ClosedRange<TimeInterval>?
    public var referenceImages: ClosedRange<Int>?
    public var controls: Set<Control>
    /// A job needs a prompt even with a source.
    public var requiresPrompt: Bool
    /// The list price bills the source video's seconds too (`Pricing.tariffID`).
    public var billsSourceVideo: Bool
    /// The list price is what the job costs, rather than an estimate.
    public var listPriceIsExact: Bool
    public var shape: RequestShape
    /// REST endpoints by the keys `VideoModel.endpointID(for:resolution:hasMedia:usesFrames:)` tries; empty for a
    /// model that runs on the account only (`VideoModel.runsWithAPIKey`).
    public var endpoints: [String: String]
    /// The account's `generate_video` model ID by mode; empty for a model that runs with an API key only.
    public var accountModels: [Mode: String]
    public var credits: Credits

    /// A model `models.json` doesn't describe: serves nothing, so nothing runs on it.
    static func unknown(_ id: String) -> VideoModelDescriptor {
        VideoModelDescriptor(
            id: id, family: id, title: id, detail: "", modes: [], resolutions: Resolution.standard, aspectRatios: [],
            duration: nil, referenceImages: nil, controls: [],
            requiresPrompt: false, billsSourceVideo: false, listPriceIsExact: false, shape: .genjutsu, endpoints: [:],
            accountModels: [:],
            credits: Credits(base: 0, perSecond: [:]))
    }
}

extension VideoModelDescriptor: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, family, title, detail, modes, resolutions, aspectRatios, limits, controls, requiresPrompt
        case billsSourceVideo, listPriceIsExact, request, credits
    }

    private struct Limits: Decodable {
        var duration: [TimeInterval]?
        var referenceImages: [Int]?
    }

    private struct Request: Decodable {
        var shape: String
        var endpoints: [String: String]
        var account: [String: String]?
    }

    private struct CreditsFile: Decodable {
        var base: Double?
        var perSecond: [String: Double]
        var modes: [String: CreditsFile]?
    }

    /// Fails on anything this version can't run exactly as described: an unknown mode, control, request shape,
    /// resolution or frame, an empty list of resolutions, or a limit that isn't a range.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        family = try container.decode(String.self, forKey: .family)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        modes = try container.decode([Mode].self, forKey: .modes)
        if let listed = try container.decodeIfPresent([String].self, forKey: .resolutions) {
            let resolutions: [Resolution] = try listed.map { try Self.value($0, key: .resolutions, in: container) }
            guard !resolutions.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .resolutions, in: container, debugDescription: "No resolution")
            }
            self.resolutions = Resolution.allCases.filter(resolutions.contains)
        } else {
            resolutions = Resolution.standard
        }
        let frames = try container.decodeIfPresent([String].self, forKey: .aspectRatios) ?? []
        aspectRatios = try frames.map { try Self.value($0, key: .aspectRatios, in: container) }
        let limits = try container.decodeIfPresent(Limits.self, forKey: .limits)
        duration = try limits?.duration.map { try Self.range($0, key: .limits, in: container) }
        referenceImages = try limits?.referenceImages.map { try Self.range($0, key: .limits, in: container) }
        let controls = try container.decodeIfPresent([String].self, forKey: .controls) ?? []
        self.controls = Set(try controls.map { try Self.value($0, key: .controls, in: container) })
        requiresPrompt = try container.decodeIfPresent(Bool.self, forKey: .requiresPrompt) ?? false
        billsSourceVideo = try container.decodeIfPresent(Bool.self, forKey: .billsSourceVideo) ?? false
        listPriceIsExact = try container.decodeIfPresent(Bool.self, forKey: .listPriceIsExact) ?? false
        let request = try container.decode(Request.self, forKey: .request)
        shape = try Self.value(request.shape, key: .request, in: container)
        endpoints = request.endpoints
        accountModels = try (request.account ?? [:]).reduce(into: [:]) { result, entry in
            let mode: Mode = try Self.value(entry.key, key: .request, in: container)
            result[mode] = entry.value
        }
        let credits = try container.decodeIfPresent(CreditsFile.self, forKey: .credits)
        self.credits = try credits.map { try Self.credits($0, in: container) } ?? Credits(base: 0, perSecond: [:])
    }

    private static func credits(
        _ file: CreditsFile, in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Credits {
        Credits(
            base: file.base ?? 0,
            perSecond: try file.perSecond.reduce(into: [:]) { result, entry in
                let resolution: Resolution = try value(entry.key, key: .credits, in: container)
                result[resolution] = entry.value
            },
            modes: try (file.modes ?? [:]).reduce(into: [:]) { result, entry in
                let mode: Mode = try value(entry.key, key: .credits, in: container)
                result[mode] = try credits(entry.value, in: container)
            })
    }

    private static func value<Value: RawRepresentable>(
        _ raw: String, key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Value where Value.RawValue == String {
        guard let value = Value(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Unknown \"\(raw)\"")
        }
        return value
    }

    private static func range<Bound: Comparable>(
        _ bounds: [Bound], key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ClosedRange<Bound> {
        guard bounds.count == 2, bounds[0] <= bounds[1] else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Not a range")
        }
        return bounds[0]...bounds[1]
    }
}

/// The video models the app knows, from `models.json`, in the order the picker lists them.
public struct VideoModelCatalog: Sendable, Hashable {
    public let descriptors: [VideoModelDescriptor]
    /// How many entries the file had, including the ones this version can't read.
    public let entryCount: Int
    private let byID: [String: VideoModelDescriptor]

    /// Decodes the `models.json` format. An entry this version can't read is left out, so a newer file still loads
    /// the models it can run; so is a second entry with an ID already listed.
    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        var seen = Set<String>()
        self.init(
            descriptors: file.models.compactMap(\.value).filter { seen.insert($0.id).inserted },
            entryCount: file.models.count)
    }

    /// The bundled `models.json`; empty if it can't be read, which the catalog tests rule out.
    public static let bundled: VideoModelCatalog = {
        guard let url = JutsuCoreResources.modelsURL, let data = try? Data(contentsOf: url),
            let catalog = try? VideoModelCatalog(data: data)
        else { return VideoModelCatalog(descriptors: [], entryCount: 0) }
        return catalog
    }()

    private init(descriptors: [VideoModelDescriptor], entryCount: Int) {
        self.descriptors = descriptors
        self.entryCount = entryCount
        byID = Dictionary(descriptors.map { ($0.id, $0) }) { first, _ in first }
    }

    public subscript(id: String) -> VideoModelDescriptor? { byID[id] }

    private struct File: Decodable {
        let models: [Lossy<VideoModelDescriptor>]
    }
}

/// A value that is `nil` where decoding it failed, so one bad element doesn't fail the array it is in.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
