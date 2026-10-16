import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import JutsuCore

/// Virality scores of the account's results (issues #45, #111), confirmed by a live run on 2026-10-15.
enum AccountVirality {
    /// A live run on 2026-10-15 left the balance unchanged: scoring a video is free.
    static let price = Cost.credits(0, isEstimate: false)
    /// The pause between polls when the answer names none; the live answer said 1.5 s.
    static let defaultPollInterval = 1.5
    /// No pause is longer than this, whatever the answer asks.
    static let maximumPollInterval = 10.0
    /// How many times a job is polled before the app gives up on it: about 5 minutes at the live 1.5 s (the live
    /// job took about one).
    static let maximumPolls = 200

    static func pause(_ pollInterval: Double?) -> Duration {
        .seconds(min(pollInterval ?? defaultPollInterval, maximumPollInterval))
    }

    static func outcome(_ prediction: ViralityPrediction?, scoredAt: Date) -> ViralityOutcome {
        ViralityOutcome(score: prediction.map { score($0, scoredAt: scoredAt) }, charged: price)
    }

    static func score(_ prediction: ViralityPrediction, scoredAt: Date) -> ViralityScore {
        ViralityScore(
            score: whole(prediction.overall), viralPotential: whole(prediction.viralPotential),
            hook: whole(prediction.hook), engagement: whole(prediction.engagement), sustain: whole(prediction.sustain),
            peakSecond: prediction.peakSecond, perFrame: prediction.perFrame.isEmpty ? nil : prediction.perFrame,
            disclaimer: prediction.disclaimer, reportURL: prediction.dashboardURL, scoredAt: scoredAt)
    }

    private static func whole(_ value: Double?) -> Int? {
        value.flatMap { Int(exactly: $0.rounded()) }
    }

    static let failed = String(localized: "Higgsfield couldn't score this video.", bundle: .module)
    static let timedOut = String(localized: "Higgsfield is still scoring this video. Try again later.", bundle: .module)
}

extension HiggsfieldMCPProvider: ViralityScoring {
    public static var offersVirality: Bool { true }

    /// Free, as the live run showed; nothing is asked.
    public func viralityEstimate(jobID: String) async throws -> Cost? {
        return AccountVirality.price
    }

    /// Starts the Virality Predictor job and polls it with `job_status` (only that answer carries the readings)
    /// until it ends. The call is free, so an answer lost on the way is an ordinary error the user can retry.
    public func scoreVirality(jobID: String) async throws -> ViralityOutcome {
        let job = try await mapped { try await account.predictVirality(jobID: jobID) }
        let pause = AccountVirality.pause(job.pollInterval)
        for _ in 0..<AccountVirality.maximumPolls {
            try await Task.sleep(for: pause)
            switch try await mapped({ try await account.viralityStatus(of: job.id) }) {
            case .running:
                continue
            case .completed(let prediction):
                return AccountVirality.outcome(prediction, scoredAt: Date())
            case .failed(let message):
                throw ProviderError.validation(field: nil, message: message ?? AccountVirality.failed)
            }
        }
        throw ProviderError.validation(field: nil, message: AccountVirality.timedOut)
    }
}
