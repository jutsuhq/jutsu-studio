import JutsuCore

extension JobSpec {
    /// The spec as far as its price goes: the same without the prompt, which no provider prices by
    /// (`GenerationProvider.estimate`). Estimates are kept by this, so typing a prompt reuses the price.
    public var priceKey: JobSpec {
        var key = self
        key.prompt = ""
        return key
    }
}

/// The Create screen's provider estimates, by `JobSpec.priceKey`, for one connection.
public struct EstimateCache: Sendable, Hashable {
    /// By price key.
    public private(set) var costs: [JobSpec: Cost] = [:]
    /// The last complete total of Draft (`true`) and Generate (`false`). A changed form shows it until its own
    /// estimate arrives, so the buttons keep a price instead of blinking; it never decides a submit.
    public private(set) var lastTotals: [Bool: Cost] = [:]

    public init() {}

    /// The price keys of `specs` that have no estimate yet, each once, in order.
    public func missing(_ specs: [JobSpec]) -> [JobSpec] {
        var seen: Set<JobSpec> = []
        return specs.map(\.priceKey).filter { costs[$0] == nil && seen.insert($0).inserted }
    }

    /// Adds `fresh` estimates, then remembers the totals of `generate` and `draft` that are now fully known.
    public mutating func record(_ fresh: [JobSpec: Cost], generate: [JobSpec], draft: [JobSpec]) {
        for (spec, cost) in fresh { costs[spec.priceKey] = cost }
        for (isDraft, specs) in [(false, generate), (true, draft)] {
            if let total = total(of: specs) { lastTotals[isDraft] = total }
        }
    }

    /// The sum over `specs`; `nil` when any is unknown, or when there are none.
    func total(of specs: [JobSpec]) -> Cost? {
        let known = specs.compactMap { costs[$0.priceKey] }
        return known.count == specs.count ? Cost.total(known) : nil
    }

    /// Waits for `debounce` first, so dragging a trim handle or typing a length doesn't ask on every step: a form
    /// changed during the wait cancels the task, and then nothing is asked (`nil`). Then like
    /// `estimate(_:with:)`. Account quotes are free, but each is a call to Higgsfield.
    public static func estimate(
        _ keys: [JobSpec], after debounce: Duration,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        with estimate: @escaping @Sendable (JobSpec) async -> Cost?
    ) async -> [JobSpec: Cost]? {
        guard !keys.isEmpty else { return [:] }
        do {
            try await sleep(debounce)
            try Task.checkCancellation()
        } catch {
            return nil
        }
        return await Self.estimate(keys, with: estimate)
    }

    /// Asks `estimate` for every key at once rather than one after another; keys it can't price are left out.
    public static func estimate(
        _ keys: [JobSpec], with estimate: @escaping @Sendable (JobSpec) async -> Cost?
    ) async -> [JobSpec: Cost] {
        await withTaskGroup(of: (JobSpec, Cost?).self) { group in
            for key in keys {
                group.addTask { (key, await estimate(key)) }
            }
            var costs: [JobSpec: Cost] = [:]
            for await (key, cost) in group {
                if let cost { costs[key] = cost }
            }
            return costs
        }
    }
}
