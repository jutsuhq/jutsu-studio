import Foundation
import HiggsfieldCore

/// A model's limits as a `models_explore` `get` answer states them: the `duration` parameter's range and how many
/// reference images the `medias` take. Every bound is optional, `nil` where the answer doesn't state it.
///
/// The catalog snapshot of 2026-10-15 confirms the shape of the answer: the model itself, its `parameters` an array
/// of `{name, min, max, default, options, required}` (Seedance 2.5's `duration` is 4–30; Genjutsu and Kling 3.0
/// Motion Control state none), and `medias` entries with `roles` but no counts, so the image bounds stay `nil`.
/// Other shapes are still read (`docs/higgsfield-api.md` 4.5): the model under `model` or `data`; parameters as an
/// object by name (or its `properties`); a bound as `minimum`/`maximum`, or an `enum`/`values` of numbers; media
/// entries with `role` (`image_references`, `image`) or `type: "image"`, counted by `min`/`min_count`/`minItems`/
/// `minimum` and `max`/`max_count`/`maxItems`/`maximum`. Anything else is `nil`.
public struct ModelLimits: Sendable, Hashable {
    public var minDuration: Double?
    public var maxDuration: Double?
    public var minImages: Int?
    public var maxImages: Int?

    public init(minDuration: Double? = nil, maxDuration: Double? = nil, minImages: Int? = nil, maxImages: Int? = nil) {
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.minImages = minImages
        self.maxImages = maxImages
    }

    /// From one `get` answer.
    init(answer: JSONValue) {
        let model = Self.modelKeys.lazy.compactMap { answer[$0] }.first { $0.objectValue != nil } ?? answer
        if let duration = Self.parameter(ToolKey.duration, in: model) {
            (minDuration, maxDuration) = Self.bounds(of: duration)
        }
        if let images = Self.imageMedia(in: model) {
            let (minimum, maximum) = Self.bounds(of: images, lower: Self.minCountKeys, upper: Self.maxCountKeys)
            (minImages, maxImages) = (minimum.flatMap(Self.count), maximum.flatMap(Self.count))
        }
    }

    static let modelKeys = [ToolKey.model, ToolKey.data]
    static let parameterKeys = ["parameters", ToolKey.params]
    static let mediaKeys = [ToolKey.medias, "media"]
    static let imageRoles: Set<String> = ["image_references", "image"]
    static let minKeys = ["minimum", "min"]
    static let maxKeys = ["maximum", "max"]
    static let minCountKeys = ["min", "min_count", "minItems", "minimum"]
    static let maxCountKeys = ["max", "max_count", "maxItems", "maximum"]
    static let enumKeys = ["enum", "values"]

    /// The parameter named `name`, from `parameters` (or `params`) as an object by name, its JSON-schema
    /// `properties`, or an array of objects with `name`.
    static func parameter(_ name: String, in model: JSONValue) -> JSONValue? {
        for key in parameterKeys {
            guard let parameters = model[key] else { continue }
            if let found = parameters["properties"]?[name] ?? parameters[name] { return found }
            if let found = parameters.arrayValue?.first(where: { $0["name"]?.stringValue == name }) { return found }
        }
        return nil
    }

    /// The `medias` entry for reference images, at the top or in the parameters.
    static func imageMedia(in model: JSONValue) -> JSONValue? {
        let holders = [model] + parameterKeys.compactMap { model[$0] }
        let entries = holders.flatMap { holder in mediaKeys.compactMap { holder[$0]?.arrayValue }.joined() }
        return entries.first { entry in
            let roles =
                [entry["role"]?.stringValue].compactMap(\.self)
                + (entry["roles"]?.arrayValue ?? []).compactMap(\.stringValue)
            return !imageRoles.isDisjoint(with: roles) || (roles.isEmpty && entry[ToolKey.type] == "image")
        }
    }

    /// `lower` and `upper` as numbers; else the least and greatest of an enum of numbers whose whole numbers run
    /// without a gap (4, 5, 6), since a range can't say "5 or 10".
    static func bounds(of spec: JSONValue, lower: [String] = minKeys, upper: [String] = maxKeys) -> (Double?, Double?) {
        let minimum = lower.lazy.compactMap { spec[$0]?.numberValue }.first(where: \.isFinite)
        let maximum = upper.lazy.compactMap { spec[$0]?.numberValue }.first(where: \.isFinite)
        if minimum != nil || maximum != nil { return (minimum, maximum) }
        guard let values = enumKeys.lazy.compactMap({ spec[$0]?.arrayValue }).first else { return (nil, nil) }
        let numbers = values.compactMap(\.numberValue)
        guard numbers.count == values.count, numbers.allSatisfy({ $0.isFinite && $0 == $0.rounded() }),
            let low = numbers.min(), let high = numbers.max(), Double(Set(numbers).count) == high - low + 1
        else { return (nil, nil) }
        return (low, high)
    }

    /// A whole count of 0 or more.
    static func count(_ value: Double) -> Int? {
        guard value >= 0 else { return nil }
        return Int(exactly: value)
    }
}

extension HiggsfieldAccount {
    /// The limits of each of `models` from `models_explore` `get`; `nil` when the account has no `models_explore`.
    /// A model the server refuses to describe, or answers with an error, is left out. Free and read-only; the app
    /// calls it at most once a day per account and caches the result.
    public func modelLimits(of models: [VideoRequest.Model]) async throws -> [VideoRequest.Model: ModelLimits]? {
        guard try await lookUp(.modelsExplore, recheckingAfter: Self.optionalToolRecheck) != nil else { return nil }
        var limits: [VideoRequest.Model: ModelLimits] = [:]
        for model in models {
            let result: MCPToolResult
            do {
                (result, _) = try await exploreModels([
                    ToolKey.action: .string(ToolKey.get), ToolKey.modelID: .string(model.rawValue),
                ])
            } catch HiggsfieldError.validation {
                continue
            }
            guard !result.isError, let answer = result.value else { continue }
            limits[model] = ModelLimits(answer: answer)
        }
        return limits
    }
}
