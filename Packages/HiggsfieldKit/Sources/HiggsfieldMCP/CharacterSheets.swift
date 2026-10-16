import Foundation
import HiggsfieldCore

// AI Influencer character sheets as the catalog snapshot of 2026-10-15 states them (`docs/mcp-snapshots/2026-10-15.json`),
// checked against live answers of the free calls (`docs/mcp-snapshots/live-2026-10-15/`): `get_options`,
// `list_presets`, `prepare` and an empty `assets_picker_list` `source: "influencer"`. A character for Genjutsu is not a
// trained Soul: it is a character sheet, an ordinary image job.
//
// - `ai_influencer_get_options {tier?}` (read-only, free) answers `{tiers, groups: [{id, label, max, options: [{id,
//   label, slot, tiers}]}]}`.
// - `ai_influencer_list_presets {cursor?, size?}` (read-only) answers `{total, cursor, items: [{id, name, preview:
//   {url, thumbnail_url, type, width, height}, sheet: {…}, priority, recreate: {job_set_type, params: {tier, selection,
//   brief, seed, medias: []}} | null, recreate_unavailable_reason}]}`. Live, a first page of 3 answered `cursor: 2`:
//   the next page's number, pages counted from 1.
// - `ai_influencer_prepare` (read-only, free, not idempotent: a randomized design differs each time) takes `tier`,
//   `selection` (trait IDs by group, at most 4 each), `brief` (≤ 4000), `seed` (1–1 000 000), `batch_size` (1–4), at
//   most one identity image in `medias` and up to three style images in `item_medias`, each `{role: "image", data: {id,
//   type: media_input | image_job}}`, and `randomize`. It answers `{params, credits, free_gens_remaining?, submitted:
//   false}`: the exact params to generate and their price for the whole batch, in fractions of a credit (live: 1.125
//   for one sheet, 4.5 for four). The live answer left out `free_gens_remaining`.
// - `ai_influencer_generate {params, max_credits, use_free_gens?}` (paid, not idempotent) takes those params unchanged,
//   rechecks the price and refuses one above `max_credits`. It answers `{submitted: false, credits, error}` when it
//   refused, else `{submitted: true, job_id, job_ids, credits, use_free_gens, results}`. Every job ID is a sheet to
//   wait for; a resent call may start and charge another batch, so an uncertain submit is never sent again.
// - A finished sheet is an image job. `generate_video` takes its job ID in `medias[].value` like any earlier
//   generation; Genjutsu's motion gallery takes it as `get_presets` `initial_inputs.character_sheet: [{id, type:
//   "image_job"}]`, which only prefills the gallery's widget.

/// A trait group of the AI Influencer builder: "Hair", "Eyes"…
public struct InfluencerTraitGroup: Sendable, Hashable {
    public struct Option: Sendable, Hashable {
        public var id: String
        public var label: String
        /// The tiers the option is offered for.
        public var tiers: [String]

        public init(id: String, label: String, tiers: [String]) {
            self.id = id
            self.label = label
            self.tiers = tiers
        }
    }

    public var id: String
    public var label: String
    /// How many options of the group one design takes.
    public var max: Int
    public var options: [Option]

    public init(id: String, label: String, max: Int, options: [Option]) {
        self.id = id
        self.label = label
        self.max = max
        self.options = options
    }
}

/// A character sheet preset, with the settings that recreate it when it has them.
public struct InfluencerPreset: Sendable, Hashable {
    /// What `recreate.params` holds: the design without images.
    public struct Design: Sendable, Hashable {
        public var tier: String
        public var selection: [String: [String]]
        public var brief: String
        public var seed: Int?

        public init(tier: String, selection: [String: [String]], brief: String, seed: Int?) {
            self.tier = tier
            self.selection = selection
            self.brief = brief
            self.seed = seed
        }
    }

    public var id: String
    public var name: String
    public var previewURL: URL?
    public var sheetURL: URL?
    /// `nil` when the preset can't be recreated (`unavailableReason` says why).
    public var design: Design?
    public var unavailableReason: String?

    public init(
        id: String, name: String, previewURL: URL? = nil, sheetURL: URL? = nil, design: Design? = nil,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.previewURL = previewURL
        self.sheetURL = sheetURL
        self.design = design
        self.unavailableReason = unavailableReason
    }
}

public struct InfluencerPresetPage: Sendable, Hashable {
    public var items: [InfluencerPreset]
    /// The next page's `cursor`; `nil` on the last page.
    public var nextCursor: Int?

    public init(items: [InfluencerPreset], nextCursor: Int?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// An image a design names: an upload's `media_id` or a finished image job's ID.
public struct InfluencerImage: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case mediaInput = "media_input"
        case imageJob = "image_job"
    }

    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    var argument: JSONValue {
        [
            ToolKey.role: .string(ToolKey.image),
            ToolKey.data: [ToolKey.id: .string(id), ToolKey.type: .string(kind.rawValue)],
        ]
    }
}

/// What `ai_influencer_prepare` is asked to design and price.
public struct InfluencerDesign: Sendable, Hashable {
    /// `nil` leaves it to the server: random with `randomize`, "freak" without.
    public var tier: String?
    /// Option IDs by group ID; at most 4 per group are sent.
    public var selection: [String: [String]]
    public var brief: String
    public var seed: Int?
    /// Sheets, 1–4.
    public var batchSize: Int
    /// The face to keep, at most one.
    public var identity: InfluencerImage?
    /// Style references, at most three.
    public var styles: [InfluencerImage]
    /// Fill the traits left unset at random.
    public var randomize: Bool

    public init(
        tier: String?, selection: [String: [String]] = [:], brief: String = "", seed: Int? = nil, batchSize: Int = 1,
        identity: InfluencerImage? = nil, styles: [InfluencerImage] = [], randomize: Bool = true
    ) {
        self.tier = tier
        self.selection = selection
        self.brief = brief
        self.seed = seed
        self.batchSize = batchSize
        self.identity = identity
        self.styles = styles
        self.randomize = randomize
    }

    static let maxBrief = 4000
    static let maxPerGroup = 4
    static let maxStyles = 3
    static let seeds = 1...1_000_000
    static let batchSizes = 1...4

    var arguments: [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            ToolKey.selection: .object(
                selection.filter { !$0.value.isEmpty }.mapValues {
                    .array($0.prefix(Self.maxPerGroup).map(JSONValue.string))
                }),
            ToolKey.brief: .string(String(brief.prefix(Self.maxBrief))),
            ToolKey.batchSize: .number(
                Double(min(max(batchSize, Self.batchSizes.lowerBound), Self.batchSizes.upperBound))),
            ToolKey.medias: .array(identity.map { [$0.argument] } ?? []),
            ToolKey.itemMedias: .array(styles.prefix(Self.maxStyles).map(\.argument)),
            ToolKey.randomize: .bool(randomize),
        ]
        if let tier { arguments[ToolKey.tier] = .string(tier) }
        if let seed, Self.seeds.contains(seed) { arguments[ToolKey.seed] = .number(Double(seed)) }
        return arguments
    }
}

/// `ai_influencer_prepare`'s answer: the exact params to generate, and their price.
public struct InfluencerQuote: Sendable, Hashable {
    /// Sent to `ai_influencer_generate` unchanged.
    public var params: JSONValue
    /// The price of the whole batch.
    public var credits: Double
    public var freeGensRemaining: Int?

    public init(params: JSONValue, credits: Double, freeGensRemaining: Int? = nil) {
        self.params = params
        self.credits = credits
        self.freeGensRemaining = freeGensRemaining
    }
}

/// What `ai_influencer_generate` started: one job per sheet.
public struct InfluencerSubmission: Sendable, Hashable {
    /// Every job ID the answer names, the first job's first; never empty.
    public var jobIDs: [String]
    /// What the answer says it charged.
    public var credits: Double?

    public init(jobIDs: [String], credits: Double?) {
        self.jobIDs = jobIDs
        self.credits = credits
    }
}

extension InfluencerTraitGroup {
    init?(_ value: JSONValue) {
        guard let id = value[ToolKey.id]?.stringValue, !id.isEmpty else { return nil }
        let options = (value[ToolKey.options]?.arrayValue ?? []).compactMap { option -> Option? in
            guard let id = option[ToolKey.id]?.stringValue, !id.isEmpty else { return nil }
            return Option(
                id: id, label: option[ToolKey.label]?.stringValue ?? id,
                tiers: (option[ToolKey.tiers]?.arrayValue ?? []).compactMap(\.stringValue))
        }
        self.init(
            id: id, label: value[ToolKey.label]?.stringValue ?? id,
            max: value[ToolKey.max]?.numberValue.flatMap(ModelLimits.count) ?? 1, options: options)
    }
}

extension InfluencerPreset {
    init?(_ value: JSONValue) {
        guard let id = value[ToolKey.id]?.stringValue, !id.isEmpty else { return nil }
        let params = value[ToolKey.recreate]?[ToolKey.params]
        let design = params.flatMap { params -> Design? in
            guard let tier = params[ToolKey.tier]?.stringValue else { return nil }
            let selection = (params[ToolKey.selection]?.objectValue ?? [:]).mapValues {
                ($0.arrayValue ?? []).compactMap(\.stringValue)
            }
            return Design(
                tier: tier, selection: selection, brief: params[ToolKey.brief]?.stringValue ?? "",
                seed: params[ToolKey.seed]?.numberValue.flatMap(ModelLimits.count))
        }
        self.init(
            id: id, name: value[ToolKey.name]?.stringValue ?? "",
            previewURL: (value[ToolKey.preview]?[ToolKey.thumbnailURL]?.stringValue
                ?? value[ToolKey.preview]?[ToolKey.url]?.stringValue).flatMap(URL.init(serverMedia:)),
            sheetURL: value[ToolKey.sheet]?[ToolKey.url]?.stringValue.flatMap(URL.init(serverMedia:)), design: design,
            unavailableReason: value[ToolKey.recreateUnavailableReason]?.stringValue)
    }
}

extension HiggsfieldAccount {
    /// The trait groups, each with the options of `tier` only; every tier's when `tier` is `nil`.
    public func influencerOptions(tier: String?) async throws -> [InfluencerTraitGroup] {
        var arguments: [String: JSONValue] = [:]
        if let tier { arguments[ToolKey.tier] = .string(tier) }
        let value = try await call(.influencerOptions, arguments)
        guard let groups = value[ToolKey.groups]?.arrayValue else { throw failure(value, role: .influencerOptions) }
        return groups.compactMap(InfluencerTraitGroup.init).map { group in
            var group = group
            if let tier { group.options.removeAll { !$0.tiers.isEmpty && !$0.tiers.contains(tier) } }
            return group
        }
    }

    /// A page of the character sheet presets, in the server's order.
    /// - Parameters:
    ///   - cursor: `nextCursor` of the page before.
    ///   - size: 1–100.
    public func influencerPresets(cursor: Int? = nil, size: Int = 30) async throws -> InfluencerPresetPage {
        let size = min(max(size, 1), 100)
        var arguments: [String: JSONValue] = [ToolKey.size: .number(Double(size))]
        if let cursor, cursor >= 1 { arguments[ToolKey.cursor] = .number(Double(cursor)) }
        let value = try await call(.influencerPresets, arguments)
        guard let items = value[ToolKey.items]?.arrayValue else { throw failure(value, role: .influencerPresets) }
        let presets = items.compactMap(InfluencerPreset.init)
        // A short page is the last; an empty one that still named a next one would never end.
        let cursor = value[ToolKey.cursor]?.numberValue.flatMap(ModelLimits.count).flatMap { $0 > 0 ? $0 : nil }
        let next = items.count < size ? nil : cursor
        return InfluencerPresetPage(items: presets, nextCursor: next)
    }

    /// The exact params and price of `design`; free and starts nothing. A randomized design differs each time it is
    /// asked for, so what is generated is always the quote's `params`, never the design again.
    public func prepareInfluencer(_ design: InfluencerDesign) async throws -> InfluencerQuote {
        let value = try await call(.influencerPrepare, design.arguments)
        guard let params = value[ToolKey.params], params.objectValue != nil,
            let credits = value[ToolKey.credits]?.numberValue, credits.isFinite, credits >= 0
        else { throw failure(value, role: .influencerPrepare) }
        return InfluencerQuote(
            params: params, credits: credits,
            freeGensRemaining: value[ToolKey.freeGensRemaining]?.numberValue.flatMap(ModelLimits.count))
    }

    /// Starts the quoted sheets, paid from the account's credits up to `maxCredits`; never with free generations.
    /// Not idempotent: sending it again may start and charge another batch. A refusal (`submitted: false` with its
    /// `error`, or `isError`) throws `.validation`: nothing started. An answer that names no job and gives no reason
    /// throws `.server(status: 200)`, as it may have started some.
    public func generateInfluencer(_ quote: InfluencerQuote, maxCredits: Double) async throws -> InfluencerSubmission {
        let value = try await call(
            .influencerGenerate, [ToolKey.params: quote.params, ToolKey.maxCredits: .number(max(maxCredits, 0))])
        var ids: [String] = []
        let named =
            [value[ToolKey.jobIDSingle]?.stringValue].compactMap(\.self)
            + (value[ToolKey.jobIDs]?.arrayValue ?? []).compactMap(\.stringValue)
        for id in named where !id.isEmpty && !ids.contains(id) { ids.append(id) }
        guard !ids.isEmpty else { throw Self.noJobStarted(value) }
        return InfluencerSubmission(jobIDs: ids, credits: value[ToolKey.credits]?.numberValue)
    }

    /// A page of `assets_picker_list` `source: "influencer"`, images only. The snapshot lists the source without
    /// saying what it holds; it is read as the account's character sheets, each by its job ID.
    public func influencerSheets(cursor: JSONValue? = nil, size: Int = 30) async throws -> AccountAssetPage {
        try await assets(source: ToolKey.influencer, kind: .image, cursor: cursor, size: size)
    }
}
