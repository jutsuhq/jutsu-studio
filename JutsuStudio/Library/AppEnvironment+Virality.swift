import Foundation
import HiggsfieldProviders
import JutsuCore
import Persistence
import Presentation
import SwiftData

extension AppEnvironment {
    /// Whether batch comparison shows Score Variants: where the connection scores virality, the account's
    /// (confirmed live, issue #111).
    var viralityAvailability: ViralityAvailability {
        ViralityAvailability.of(scorer: viralityScorer, offered: HiggsfieldMCPProvider.offersVirality)
    }

    /// The price of scoring one of `plan`'s results; `Cost.unknownCredits` when the provider gives no quote.
    func viralityEstimate(_ plan: ViralityPlan) async -> Cost {
        guard let scorer = viralityScorer, let entry = plan.entries.first else { return .unknownCredits }
        do {
            return try await scorer.viralityEstimate(jobID: entry.jobID) ?? .unknownCredits
        } catch {
            libraryLogger.error("Can't quote a virality score: \(String(describing: error), privacy: .private)")
            return .unknownCredits
        }
    }

    /// Keeps `score` on the result's stored job, so it isn't paid for again. A failed save is only logged.
    func saveVirality(_ score: ViralityScore, for id: UUID) {
        let context = modelContainer.mainContext
        do {
            var descriptor = FetchDescriptor<MaterialRecord>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let record = try context.fetch(descriptor).first else { return }
            var material = try record.material()
            guard var job = material.current.video else { return }
            job.virality = score
            material.current.video = job
            try record.update(material)
            try context.save()
        } catch {
            libraryLogger.error("Can't save a virality score: \(String(describing: error), privacy: .private)")
        }
    }
}
