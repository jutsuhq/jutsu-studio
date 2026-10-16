import Foundation
import JutsuCore
import Observation
import Presentation

/// Everything on the Create screen that needs a network or store round-trip: capabilities,
/// the style catalog, credit estimates and today's spend. The View keeps transient UI state
/// (alerts, dialogs, picking, the probe); the loader owns server-driven data, so the `.task`
/// loaders live in one place instead of the View body.
@MainActor
@Observable
final class CreateLoader {
    var catalog: PresetCatalog?
    var capabilities: Capabilities?
    var pricing: Pricing? = try? Pricing.bundled()
    private(set) var estimates = EstimateCache()
    /// The connection `estimates` were made on; another one prices differently.
    private var estimatesGeneration: Int?
    var committedToday: Decimal = 0
    var spendError: String?

    func refreshCapabilities(_ environment: AppEnvironment) async {
        capabilities = await environment.capabilities()
        environment.lastOfferedModels = capabilities?.models ?? [.genjutsu]
    }

    func refreshPresets(_ environment: AppEnvironment) async {
        let catalog = self.catalog ?? PresetCatalog(cacheFolder: environment.layout.presetCacheFolder)
        if self.catalog == nil {
            await catalog.loadCache()
            self.catalog = catalog
        }
        guard let provider = environment.provider else { return }
        await catalog.refresh { try await provider.presets() }
    }

    func refreshCommitted(_ environment: AppEnvironment, unit: Capabilities.CostUnit) async {
        do {
            committedToday = try await environment.committedToday(in: unit)
            spendError = nil
        } catch {
            spendError = error.localizedDescription
        }
    }

    /// Estimates the specs of Generate and Draft not priced yet, all at once. The buttons keep the last known
    /// price meanwhile (`EstimateCache.lastTotals`).
    /// - Parameters:
    ///   - request: `nil` when nothing needs an estimate.
    ///   - debounce: wait for a pause first, so dragging a trim handle doesn't ask on every step.
    func loadEstimates(_ request: EstimateRequest?, environment: AppEnvironment, debounce: Bool = true) async {
        guard let request else { return }
        if estimatesGeneration != request.generation {
            estimates = EstimateCache()
            estimatesGeneration = request.generation
        }
        let missing = estimates.missing(request.generate + request.draft)
        let pause: Duration = debounce ? .milliseconds(400) : .zero
        let estimate: @Sendable (JobSpec) async -> Cost? = { await environment.estimate($0) }
        guard let fresh = await EstimateCache.estimate(missing, after: pause, with: estimate) else { return }
        // Another connection's prices; the next load asks again.
        guard estimatesGeneration == request.generation else { return }
        estimates.record(fresh, generate: request.generate, draft: request.draft)
    }
}

/// The specs of the Create form to price, by `JobSpec.priceKey`, so a new prompt is the same request.
struct EstimateRequest: Hashable {
    /// `AppEnvironment.providerGeneration`.
    var generation: Int
    var generate: [JobSpec]
    var draft: [JobSpec]

    init(_ form: CreateForm, context: CreateContext, generation: Int) {
        self.generation = generation
        generate = form.makeSpecs(isDraft: false, in: context).map(\.priceKey)
        draft = form.makeSpecs(isDraft: true, in: context).map(\.priceKey)
    }
}
