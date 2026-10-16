import Foundation
import JutsuCore
import MediaKit
import Persistence
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Create")

/// Today's spend and the cap as the Create screen sees them, for the engine's checks and for the paid requests
/// outside the queue (Generate…, Create Character, Score Variants).
@MainActor
final class SpendReader {
    private let defaults: UserDefaults
    private let store: SwiftDataStore
    private let images: ImageSpendLog

    init(defaults: UserDefaults, store: SwiftDataStore, images: ImageSpendLog) {
        self.defaults = defaults
        self.store = store
        self.images = images
    }

    /// `nil` when the job's connection has no cap.
    func status(excluding job: Job) async throws -> SpendStatus? {
        guard let cap = AppSettings.spendCap(in: defaults, for: job.providerKind) else { return nil }
        let committed = try await AppEnvironment.committedToday(
            in: cap.unit, store: store, images: images, excluding: job.id)
        return SpendStatus(committedToday: committed, cap: cap)
    }

    /// `nil` when `kind`'s connection has no cap. Read by the work outside the queue before each paid request.
    func status(for kind: ProviderKind) async throws -> SpendStatus? {
        guard let cap = AppSettings.spendCap(in: defaults, for: kind) else { return nil }
        let committed = try await AppEnvironment.committedToday(in: cap.unit, store: store, images: images)
        return SpendStatus(committedToday: committed, cap: cap)
    }
}

extension AppEnvironment {
    /// Today's cap for `kind`, from the defaults this environment was built with (never `.standard`
    /// directly, so tests and previews can inject their own).
    func spendCap(for kind: ProviderKind?) -> SpendCap? {
        AppSettings.spendCap(in: defaults, for: kind)
    }

    /// What the daily cap counts, in `unit`: the jobs and the reference image requests. The store fetches and
    /// decodes off the main actor; the fetch is a superset and `DailySpend` decides which jobs were charged.
    func committedToday(in unit: Capabilities.CostUnit, now: Date = .now) async throws -> Decimal {
        try await Self.committedToday(in: unit, store: store, images: imageSpend, now: now)
    }

    /// - Parameter excluded: a job left out of the sum, e.g. the one whose own price is being checked.
    static func committedToday(
        in unit: Capabilities.CostUnit, store: SwiftDataStore, images: ImageSpendLog,
        excluding excluded: UUID? = nil, now: Date = .now
    ) async throws -> Decimal {
        let startOfDay = Calendar.current.startOfDay(for: now)
        let jobs: [Job]
        do {
            guard images.readError == nil else { throw BudgetError.spendingUnavailable }
            jobs = try await store.jobsUnfinishedOrFinished(since: startOfDay)
        } catch {
            logger.error("Can't read today's spend: \(String(describing: error), privacy: .private)")
            throw BudgetError.spendingUnavailable
        }
        return DailySpend.committed(jobs.filter { $0.id != excluded }, images: images.charges, on: now, in: unit)
    }

    /// The provider's estimate; `nil` while disconnected or when it can't be had.
    func estimate(_ spec: JobSpec) async -> Cost? {
        guard let provider else { return nil }
        do {
            return try await provider.estimate(spec)
        } catch {
            logger.error("Can't estimate: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// What queueing `spec` once more does: start, or ask first when it takes today's spend over the cap.
    func submitDecision(for spec: JobSpec) async -> SubmitDecision {
        await submitDecision(for: spec, cost: estimate(spec))
    }

    /// `submitDecision(for:)` at a price the caller already has.
    func submitDecision(for spec: JobSpec, cost: Cost?) async -> SubmitDecision {
        await submitDecision(for: [spec], cost: cost)
    }

    /// What queueing `specs` together does, at `cost`, their total: one cap check for all of them.
    func submitDecision(for specs: [JobSpec], cost: Cost?) async -> SubmitDecision {
        let cap = spendCap(for: connection.state.kind)
        guard let cap else { return .start(specs) }
        do {
            let committed = try await committedToday(in: cap.unit)
            return .budgeted(specs, cost: cost, committedToday: committed, cap: cap)
        } catch {
            return .blocked(error.localizedDescription)
        }
    }

    /// Reads what the Create screen shows about a video. `url` has to be accessible already.
    static func probeSource(_ url: URL, bookmark: Data?) async throws -> SourceVideo {
        let info = try await MediaProbe.probe(url)
        return SourceVideo(
            fileURL: url, duration: info.duration, pixelSize: info.pixelSize, codec: info.codec,
            fileSize: info.fileSize, bookmark: bookmark)
    }

    /// A bookmark for a file just picked or dropped; `nil` when it can't be made, so the job still
    /// runs in this launch and only a relaunch loses access.
    static func bookmark(for url: URL) -> Data? {
        do {
            return try SecurityScopedAccess.bookmark(for: url)
        } catch {
            logger.error("Can't bookmark a picked file: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}
