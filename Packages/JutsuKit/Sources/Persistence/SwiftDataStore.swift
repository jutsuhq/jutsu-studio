import Foundation
import JutsuCore
import SwiftData
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Persistence")

/// Job and upload storage on its own model context, so the engine writes off the main actor.
/// Views read the same container through `@Query`.
///
/// The `ModelActor` conformance is spelled out instead of using `@ModelActor` so the initializer is
/// explicitly public; it is what the macro would generate.
public actor SwiftDataStore: ModelActor, JobRepository, UploadCache {
    public nonisolated let modelExecutor: any ModelExecutor
    public nonisolated let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.modelContainer = modelContainer
    }

    // MARK: JobRepository

    public func save(_ job: Job) throws {
        do {
            let references: [MaterialInput]
            if let existing = try record(id: job.id) {
                references = try JSONDecoder().decode([MaterialInput].self, from: existing.inputReferences)
                try existing.update(from: job)
            } else {
                references = try inputs(of: job)
                let newRecord = try JobRecord(job: job, inputs: references)
                modelContext.insert(newRecord)
            }
            try registerVideo(job, inputs: references)
            try modelContext.save()
        } catch {
            // The context is shared: a change left pending would go out with the next save of another job.
            modelContext.rollback()
            throw error
        }
    }

    public func job(id: UUID) throws -> Job? {
        try record(id: id)?.job()
    }

    /// Records that don't decode are logged and skipped, so one of them (e.g. written by a newer build) can't
    /// stop the others from resuming. They stay in the store for a build that can read them.
    public func activeJobs() throws -> [Job] {
        let descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate<JobRecord> { $0.isTerminal == false },
            sortBy: [SortDescriptor(\JobRecord.createdAt, order: .forward)])
        return decodedJobs(try modelContext.fetch(descriptor))
    }

    public func activeJobIDs() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<JobRecord>(predicate: #Predicate<JobRecord> { $0.isTerminal == false })
        descriptor.propertiesToFetch = [\.id]
        return Set(try modelContext.fetch(descriptor).map(\.id))
    }

    /// Unfinished jobs and jobs finished at or after `date`: a superset of what the daily spend cap counts.
    /// Every record must decode: a partial sum must never pass the daily spend cap.
    public func jobsUnfinishedOrFinished(since date: Date) throws -> [Job] {
        let descriptor = FetchDescriptor<JobRecord>(predicate: JobRecord.unfinishedOrFinished(since: date))
        return try modelContext.fetch(descriptor).map { try $0.job() }
    }

    /// What the daily spend cap counts on `day` in `unit` (`Budget.committed`), fetched and decoded on this
    /// actor rather than the main one.
    /// - Parameter excluded: a job left out of the sum, e.g. the one whose own price is being checked.
    public func committedSpend(
        on day: Date, in unit: Capabilities.CostUnit, excluding excluded: UUID? = nil, calendar: Calendar = .current
    ) throws -> Decimal {
        let jobs = try jobsUnfinishedOrFinished(since: calendar.startOfDay(for: day))
        return Budget.committed(jobs.filter { $0.id != excluded }, on: day, in: unit, calendar: calendar)
    }

    /// The newest `limit` done jobs, for the typical generation time. Records that don't decode are skipped.
    public func doneJobs(limit: Int) throws -> [Job] {
        let done = JobState.done.storageKind
        var descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate<JobRecord> { $0.stateKind == done },
            sortBy: [SortDescriptor(\JobRecord.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return decodedJobs(try modelContext.fetch(descriptor))
    }

    /// The library, newest first, fetched and decoded on this actor rather than the main one.
    /// Records that don't decode are skipped.
    public func finishedJobs() throws -> [Job] {
        try modelContext.fetch(JobRecord.finishedNewestFirst).compactMap { try? $0.job() }
    }

    public func delete(id: UUID) throws {
        guard let existing = try record(id: id) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    // MARK: UploadCache

    public func asset(forContentHash contentHash: String, uploadedAfter date: Date) throws -> RemoteAsset? {
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate<AssetRecord> { $0.contentHash == contentHash && $0.uploadedAt >= date })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.asset
    }

    public func store(_ asset: RemoteAsset, contentHash: String, uploadedAt: Date) throws {
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate<AssetRecord> { $0.contentHash == contentHash })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(asset, uploadedAt: uploadedAt)
        } else {
            modelContext.insert(AssetRecord(contentHash: contentHash, asset: asset, uploadedAt: uploadedAt))
        }
        try modelContext.save()
    }

    public func removeAssets(uploadedBefore date: Date) throws {
        try modelContext.delete(model: AssetRecord.self, where: #Predicate<AssetRecord> { $0.uploadedAt < date })
        try modelContext.save()
    }

    /// The jobs of `records` that decode; the rest are logged and skipped, never deleted.
    private func decodedJobs(_ records: [JobRecord]) -> [Job] {
        records.compactMap { record -> Job? in
            do {
                return try record.job()
            } catch {
                logger.error(
                    "Skipped job record \(record.id, privacy: .public) that didn't decode: \(String(describing: error), privacy: .private)"
                )
                return nil
            }
        }
    }

    private func record(id: UUID) throws -> JobRecord? {
        var descriptor = FetchDescriptor<JobRecord>(predicate: #Predicate<JobRecord> { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
