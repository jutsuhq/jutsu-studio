import Foundation

/// List prices per second, from `pricing.json`, by tariff: the REST endpoint a job runs on with an API key
/// (`VideoModel.endpointID`), and for a model that bills it (Seedance) whether the source video goes with it.
public struct Pricing: Sendable, Hashable {
    public enum LoadError: Error, Hashable {
        case missingFile
        /// The tariff ID (`tariffID`) and the resolution without a rate.
        case missingRate(String, Resolution)
        /// The tariff ID and the resolution `pricing.json` lists as unpriced (`null`): no public page states it.
        case unpricedRate(String, Resolution)
    }

    /// One tariff at one resolution.
    public struct TariffKey: Sendable, Hashable {
        public var tariff: String
        public var resolution: Resolution

        public init(_ tariff: String, _ resolution: Resolution) {
            self.tariff = tariff
            self.resolution = resolution
        }
    }

    /// USD per billed second, by tariff ID.
    public let rates: [String: [Resolution: Decimal]]
    /// The tariffs `pricing.json` lists without a rate (`null`), because no public page states it: a job on one
    /// costs `Cost.unknownUSD` until the server quotes it.
    public let unpriced: Set<TariffKey>
    /// The tariffs whose rate is the top of a published range rather than their own price (`{"upTo": rate}` in
    /// `pricing.json`): a job on one is shown as costing "up to" its price, never less than it can cost, until the
    /// server quotes it.
    public let upperBounds: Set<TariffKey>

    /// Fails unless every tariff a job can have is priced, or listed as unpriced, at every resolution it can run
    /// at, so a gap in `pricing.json` stops the app at load.
    public init(
        rates: [String: [Resolution: Decimal]], unpriced: Set<TariffKey> = [], upperBounds: Set<TariffKey> = []
    ) throws {
        for (tariff, resolution) in Self.tariffs
        where rates[tariff]?[resolution] == nil && !unpriced.contains(TariffKey(tariff, resolution)) {
            throw LoadError.missingRate(tariff, resolution)
        }
        self.rates = rates
        self.unpriced = unpriced
        self.upperBounds = upperBounds
    }

    /// Decodes the `pricing.json` format: a rate, `null` for an unpriced one, or `{"upTo": rate}` for the top of a
    /// published range.
    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        var rates: [String: [Resolution: Decimal]] = [:]
        var unpriced: Set<TariffKey> = []
        var upperBounds: Set<TariffKey> = []
        for (tariff, prices) in file.models {
            for (key, value) in prices {
                guard let resolution = Resolution(rawValue: key) else { continue }
                switch value {
                case .rate(let rate):
                    rates[tariff, default: [:]][resolution] = Decimal(shortestOf: rate)
                case .upTo(let rate):
                    rates[tariff, default: [:]][resolution] = Decimal(shortestOf: rate)
                    upperBounds.insert(TariffKey(tariff, resolution))
                case .unpriced:
                    unpriced.insert(TariffKey(tariff, resolution))
                }
            }
        }
        try self.init(rates: rates, unpriced: unpriced, upperBounds: upperBounds)
    }

    public static func bundled() throws -> Pricing {
        guard let url = JutsuCoreResources.pricingURL else { throw LoadError.missingFile }
        return try Pricing(data: Data(contentsOf: url))
    }

    /// The key of a job's rates in `pricing.json`: its endpoint, with `withVideoReference` appended for a source on a
    /// model that bills the source video (`VideoModelDescriptor.billsSourceVideo`, Seedance). Seedance bills the input video's seconds too, at 0.6 of the rate for input and output alike,
    /// so a source clip costs 1.2 times the rate per second of it (open.higgsfield.ai lists this "with video
    /// reference" price separately). Edit and Extend have their own endpoints and rates (`billedSeconds(for:)`).
    public static func tariffID(
        model: VideoModel, mode: Mode, resolution: Resolution, hasSource: Bool, hasReferences: Bool,
        usesFrames: Bool = false
    ) -> String {
        // Frames only go without a source (`JobSpec.usesFrames`).
        let endpoint = model.endpointID(
            for: mode, resolution: resolution, hasMedia: hasSource || hasReferences,
            usesFrames: usesFrames && !hasSource)
        let addsVideoReference = model.descriptor.billsSourceVideo && hasSource && !mode.isVideoOperation
        return addsVideoReference ? endpoint + withVideoReference : endpoint
    }

    static let withVideoReference = " with video reference"

    /// Every tariff a job can have with an API key, with each resolution its model renders at
    /// (`VideoModel.resolutions`). A model the account alone runs (`VideoModel.runsWithAPIKey`) has none.
    static var tariffs: [(String, Resolution)] {
        var tariffs: [(String, Resolution)] = []
        for model in VideoModel.allCases where model.runsWithAPIKey {
            for mode in Mode.allCases where model.serves(mode) {
                for resolution in model.resolutions {
                    for hasSource in [true, false] {
                        for hasReferences in [true, false] {
                            for usesFrames in [true, false] {
                                let tariff = tariffID(
                                    model: model, mode: mode, resolution: resolution, hasSource: hasSource,
                                    hasReferences: hasReferences, usesFrames: usesFrames)
                                tariffs.append((tariff, resolution))
                            }
                        }
                    }
                }
            }
        }
        return tariffs
    }

    /// USD per billed second. Throws `missingRate`, or `unpricedRate` for one no page states, rather than pricing a
    /// tariff at $0.
    public func rate(
        model: VideoModel, mode: Mode, resolution: Resolution, hasSource: Bool, hasReferences: Bool,
        usesFrames: Bool = false
    ) throws -> Decimal {
        let tariff = Self.tariffID(
            model: model, mode: mode, resolution: resolution, hasSource: hasSource, hasReferences: hasReferences,
            usesFrames: usesFrames)
        guard let rate = rates[tariff]?[resolution] else {
            if unpriced.contains(TariffKey(tariff, resolution)) { throw LoadError.unpricedRate(tariff, resolution) }
            throw LoadError.missingRate(tariff, resolution)
        }
        return rate
    }

    /// Whether the tariff's rate is only the top of a published range (`upperBounds`).
    public func isUpperBound(
        model: VideoModel, mode: Mode, resolution: Resolution, hasSource: Bool, hasReferences: Bool,
        usesFrames: Bool = false
    ) -> Bool {
        let tariff = Self.tariffID(
            model: model, mode: mode, resolution: resolution, hasSource: hasSource, hasReferences: hasReferences,
            usesFrames: usesFrames)
        return upperBounds.contains(TariffKey(tariff, resolution))
    }

    public func isUpperBound(for spec: JobSpec) -> Bool {
        isUpperBound(
            model: spec.model, mode: spec.mode, resolution: spec.resolution, hasSource: spec.source != nil,
            hasReferences: !spec.references.isEmpty, usesFrames: spec.usesFrames)
    }

    public func rate(for spec: JobSpec) throws -> Decimal {
        try rate(
            model: spec.model, mode: spec.mode, resolution: spec.resolution, hasSource: spec.source != nil,
            hasReferences: !spec.references.isEmpty, usesFrames: spec.usesFrames)
    }

    /// Exact where the catalog says so (`listPriceIsExact`): Genjutsu bills whole seconds of source. Seedance bills
    /// tokens of the output frame, which the rate fits for 16:9, and Kling's rounding isn't published, so theirs is
    /// an estimate, as is the top of a range (`isUpperBound`). `Cost.unknownUSD` for an unpriced tariff, which the
    /// server's quote replaces after upload.
    public func cost(for spec: JobSpec) throws -> Cost {
        let seconds = Decimal(Self.billedSeconds(for: spec))
        do {
            let isEstimate = !spec.model.descriptor.listPriceIsExact || isUpperBound(for: spec)
            return .usd(seconds * (try rate(for: spec)), isEstimate: isEstimate)
        } catch LoadError.unpricedRate {
            return .unknownUSD
        }
    }

    /// Whole seconds a job's rate applies to. Seedance bills the source video's seconds as well as the output's,
    /// both at 0.6 of its rate: Edit's output is as long as its source, so its rate (1.2 times) is per second of
    /// source, while Extend's (0.6 times) applies to the source and the added part together.
    public static func billedSeconds(for spec: JobSpec) -> Int {
        guard spec.mode == .extend else { return billedSeconds(spec.duration) }
        return billedSeconds((spec.source?.selectedDuration ?? 0) + spec.duration)
    }

    /// Whole seconds a job is billed for on `connection`. The account bills Extend's added part alone: a 4 s
    /// extension of a 4 s clip was billed 12 credits, 4 s at 3 a second, in a live run on 2026-10-15. REST bills the
    /// source selection too (`billedSeconds(for:)`), as does any connection not known yet.
    public static func billedSeconds(for spec: JobSpec, on connection: ProviderKind?) -> Int {
        connection == .account ? billedSeconds(spec.duration) : billedSeconds(for: spec)
    }

    /// Whole seconds the API bills: the duration rounded up, ignoring float noise (12.0000001 s → 12 s).
    /// NaN and out-of-range input, which `Validation.check` rejects, clamp instead of trapping: display paths
    /// call this before validation.
    public static func billedSeconds(_ duration: TimeInterval) -> Int {
        let seconds = (duration - durationTolerance).rounded(.up)
        guard seconds > 0 else { return 0 }
        return seconds < Double(Int.max) ? Int(seconds) : .max
    }

    /// Far below one frame, far above the error of converting media timestamps to seconds.
    static let durationTolerance: TimeInterval = 1e-6

    private struct File: Decodable {
        let models: [String: [String: Rate]]
    }

    /// One resolution's entry in `pricing.json`.
    private enum Rate: Decodable {
        case rate(Double)
        case upTo(Double)
        case unpriced

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .unpriced
            } else if let rate = try? container.decode(Double.self) {
                self = .rate(rate)
            } else {
                self = .upTo(try container.decode(RangeTop.self).upTo)
            }
        }
    }

    /// `{"upTo": rate}`.
    private struct RangeTop: Decodable {
        let upTo: Double
    }
}
