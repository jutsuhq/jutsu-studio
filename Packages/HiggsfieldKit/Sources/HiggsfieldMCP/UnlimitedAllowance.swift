import Foundation

/// Whether the account can pay a `generate_video` model from its plan's unlimited allowance (`use_unlim`), as
/// `models_explore` reports it: each model item's `supports_unlim`, and the answer's top-level `unlim` block for
/// the account right now. Not keyed off the plan's name.
///
/// The catalog snapshot of 2026-10-15 confirms the shapes: a `list` answer is `{items, has_more, next_page_token,
/// unlim}`, each item names its model in `id` and carries `supports_unlim: true` only when the model takes the
/// allowance, and `unlim` is `{available, expires_at, remaining}`, `remaining` being `null` for an unmetered
/// allowance. The other keys below are still read; a field that is missing or has another shape counts as "no", so
/// the allowance is never used unless both signals were read.
public struct UnlimitedAllowance: Sendable, Hashable {
    /// The `unlim` block says the account can spend unlimited generations now.
    public var isAvailable: Bool
    /// IDs of the models whose item carries `supports_unlim: true`.
    public var supportedModels: Set<String>

    public init(isAvailable: Bool, supportedModels: Set<String>) {
        self.isAvailable = isAvailable
        self.supportedModels = supportedModels
    }

    public static let none = UnlimitedAllowance(isAvailable: false, supportedModels: [])

    /// Both signals say yes for `model`.
    public func covers(_ model: VideoRequest.Model) -> Bool {
        isAvailable && supportedModels.contains(model.rawValue)
    }

    /// From the answers of `models_explore` `list` pages: the first `unlim` block found, and the model items of
    /// every page.
    init(pages: [JSONValue]) {
        isAvailable = pages.lazy.compactMap { $0[ToolKey.unlim] }.first.map(Self.isAvailable) ?? false
        var supported: Set<String> = []
        for page in pages {
            for item in Self.items(in: page) where item[ToolKey.supportsUnlim] == true {
                if let id = Self.modelID(of: item) { supported.insert(id) }
            }
        }
        supportedModels = supported
    }

    /// The model items of a page: its `items` array, or `models` or `data`, or the answer itself when it is one.
    static func items(in page: JSONValue) -> [JSONValue] {
        if let items = page.arrayValue { return items }
        return [ToolKey.items, ToolKey.models, ToolKey.data].lazy.compactMap { page[$0]?.arrayValue }.first ?? []
    }

    /// `id`, else `model_id`, else `model`.
    static func modelID(of item: JSONValue) -> String? {
        ToolKey.modelIDs.lazy.compactMap { item[$0]?.stringValue }.first
    }

    /// The `unlim` block's flags that say the allowance can be spent now; the server sends `available`.
    static let availabilityFlags = ["available", "can_use", "enabled", "active", "eligible"]
    /// The `unlim` block's counts of what is left; the server sends `remaining`, `null` when unmetered.
    static let remainingCounts = ["remaining", "left"]

    /// `true` alone, or an object with at least one known flag or count, all of them saying yes: a flag `true`, a
    /// count above 0. A `null` count is unmetered and says nothing either way. Anything else, such as an object of
    /// unknown keys, is "no".
    static func isAvailable(_ block: JSONValue) -> Bool {
        if case .bool(let value) = block { return value }
        guard let object = block.objectValue else { return false }
        let flags = availabilityFlags.compactMap { object[$0] }
        let counts = remainingCounts.compactMap { object[$0] }.filter { $0 != .null }
        guard !flags.isEmpty || !counts.isEmpty else { return false }
        return flags.allSatisfy { $0 == true } && counts.allSatisfy { ($0.numberValue ?? 0) > 0 }
    }
}

extension HiggsfieldAccount {
    /// `models_explore` `list` pages read for the allowance, at most.
    static let maxAllowancePages = 5

    /// What `models_explore` says about the unlimited allowance; `nil` when the account has no `models_explore`.
    /// Reads `list` pages of video models (`modelPageSize` each) until each of `models` was seen, a page says the
    /// account has no allowance now, or the pages end. Free and read-only.
    public func unlimitedAllowance(for models: Set<VideoRequest.Model>) async throws -> UnlimitedAllowance? {
        guard try await lookUp(.modelsExplore, recheckingAfter: Self.optionalToolRecheck) != nil else { return nil }
        var arguments = Self.modelList(type: "video")
        var pages: [JSONValue] = []
        var seenTokens: Set<String> = []
        let wanted = Set(models.map(\.rawValue))
        for _ in 0..<Self.maxAllowancePages {
            let (result, next) = try await exploreModels(arguments)
            guard !result.isError, let page = result.value else { break }
            pages.append(page)
            let read = UnlimitedAllowance(pages: pages)
            let seen = Set(pages.flatMap(UnlimitedAllowance.items).compactMap(UnlimitedAllowance.modelID))
            guard read.isAvailable, !wanted.isSubset(of: seen), let next, seenTokens.insert(next).inserted else {
                break
            }
            arguments[ToolKey.after] = .string(next)
        }
        return UnlimitedAllowance(pages: pages)
    }
}
