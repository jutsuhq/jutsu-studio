import Foundation
import JutsuCore
import Persistence
import SwiftData
import Testing

func makeJob(
    id: UUID = UUID(), mode: Mode = .motionTransfer, createdAt: Date = Date(), state: JobState = .preparing
) -> Job {
    let source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 60, pixelSize: PixelSize(width: 1280, height: 720),
        range: 0...10)
    let spec = JobSpec(
        mode: mode, source: source, references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref.jpg"))],
        prompt: "a cat", resolution: .p720)
    var job = Job(id: id, spec: spec, providerKind: .apiKey, cost: .credits(12, isEstimate: true), createdAt: createdAt)
    job.state = state
    return job
}

@Suite struct SwiftDataStoreTests {
    let container: ModelContainer
    let store: SwiftDataStore

    init() throws {
        container = try StoreContainer.make(inMemory: true)
        store = SwiftDataStore(modelContainer: container)
    }

    @Test func savesAndFetchesJob() async throws {
        var job = makeJob()
        job.remote = RemoteJob(requestID: "r1", correlationID: "c1")
        try await store.save(job)

        #expect(try await store.job(id: job.id) == job)
        #expect(try await store.job(id: UUID()) == nil)
    }

    @Test func saveUpsertsById() async throws {
        var job = makeJob()
        try await store.save(job)
        job.state = .done
        job.progress = 1
        job.finishedAt = Date(timeIntervalSince1970: 1_000)
        job.outputFile = URL(fileURLWithPath: "/tmp/out.mp4")
        try await store.save(job)

        #expect(try await store.job(id: job.id) == job)
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<JobRecord>())
        #expect(records.count == 1)
        #expect(records.first?.stateKind == "done")
        #expect(records.first?.isTerminal == true)
        #expect(records.first?.outputPath == "/tmp/out.mp4")
        #expect(records.first?.finishedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test func starSurvivesTheEngineSavingTheJobAgain() async throws {
        var job = makeJob(state: .done)
        job.outputFile = URL(fileURLWithPath: "/tmp/result.mp4")
        try await store.save(job)
        let context = ModelContext(container)
        let record = try #require(
            try context.fetch(FetchDescriptor<MaterialRecord>(predicate: #Predicate { $0.id == job.id })).first)
        record.isStarred = true
        try context.save()
        try await store.save(job)
        #expect(
            try ModelContext(container).fetch(
                FetchDescriptor<MaterialRecord>(predicate: #Predicate { $0.id == job.id })
            ).first?.isStarred == true)
    }

    @Test func parentIDRoundTripsThroughTheStore() async throws {
        var job = makeJob()
        job.parentID = UUID()
        try await store.save(job)
        #expect(try await store.job(id: job.id)?.parentID == job.parentID)
    }

    @Test func recordKeepsQueryColumns() async throws {
        let job = makeJob(mode: .restyle, state: .failed(reason: .message("bad input")))
        try await store.save(job)

        let record = try #require(try ModelContext(container).fetch(FetchDescriptor<JobRecord>()).first)
        #expect(record.id == job.id)
        #expect(record.stateKind == "failed")
        #expect(record.isTerminal)
        #expect(!record.isDraft)
        #expect(record.modeRaw == "restyle")
        #expect(record.resolutionRaw == "720p")
        #expect(record.providerKindRaw == "apiKey")
        #expect(record.prompt == "a cat")
        #expect(record.outputPath == nil)
        #expect(try record.job() == job)
    }

    @Test func updateRejectsAnotherJob() throws {
        let record = try JobRecord(job: makeJob())
        #expect(throws: PersistenceError.jobIDMismatch) { try record.update(from: makeJob()) }
    }

    @Test func activeJobsAreNonTerminalOldestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let newer = makeJob(createdAt: base.addingTimeInterval(60), state: .queued)
        let older = makeJob(createdAt: base, state: .paused(.insufficientFunds))
        let done = makeJob(createdAt: base.addingTimeInterval(-60), state: .done)
        let canceled = makeJob(createdAt: base.addingTimeInterval(-30), state: .canceled)
        for job in [newer, done, older, canceled] {
            try await store.save(job)
        }

        #expect(try await store.activeJobs().map(\.id) == [older.id, newer.id])
    }

    @Test func activeJobsSkipUndecodableRecordsAndKeepThem() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let older = makeJob(createdAt: base, state: .queued)
        let unreadable = makeJob(createdAt: base.addingTimeInterval(30), state: .processing)
        let newer = makeJob(createdAt: base.addingTimeInterval(60), state: .processing)
        for job in [older, unreadable, newer] {
            try await store.save(job)
        }
        try writeUnknownMode(into: unreadable.id)

        #expect(try await store.activeJobs().map(\.id) == [older.id, newer.id])
        #expect(try await store.activeJobIDs() == [older.id, unreadable.id, newer.id])
        let kept = try ModelContext(container).fetch(FetchDescriptor<JobRecord>())
        #expect(Set(kept.map(\.id)) == [older.id, unreadable.id, newer.id])
    }

    @Test func spendingRejectsAnIncompleteHistoryWhileTheHistoryStillListsReadableJobs() async throws {
        let startOfDay = Date(timeIntervalSince1970: 1_000_000)
        var done = makeJob(createdAt: startOfDay, state: .done)
        done.finishedAt = startOfDay.addingTimeInterval(60)
        var unreadable = makeJob(createdAt: startOfDay.addingTimeInterval(30), state: .done)
        unreadable.finishedAt = startOfDay.addingTimeInterval(90)
        for job in [done, unreadable] {
            try await store.save(job)
        }
        try writeUnknownMode(into: unreadable.id)

        await #expect(throws: (any Error).self) {
            try await store.committedSpend(on: startOfDay, in: .credits)
        }
        #expect(try await store.doneJobs(limit: 5).map(\.id) == [done.id])
    }

    /// Rewrites a stored job as a newer build might: with a mode this build doesn't know.
    private func writeUnknownMode(into id: UUID) throws {
        let context = ModelContext(container)
        let record = try #require(
            try context.fetch(FetchDescriptor<JobRecord>(predicate: #Predicate { $0.id == id })).first)
        let json = try #require(String(data: record.jobData, encoding: .utf8))
        #expect(json.contains("\"motionTransfer\""))
        let rewritten = json.replacingOccurrences(of: "\"motionTransfer\"", with: "\"fromTheFuture\"")
        record.setValue(forKey: \.jobData, to: Data(rewritten.utf8))
        try context.save()
        #expect(throws: (any Error).self) { try record.job() }
    }

    @Test func unfinishedOrFinishedSinceSkipsOlderResults() async throws {
        let startOfDay = Date(timeIntervalSince1970: 1_000_000)
        let running = makeJob(state: .processing)
        var today = makeJob(state: .done)
        today.finishedAt = startOfDay.addingTimeInterval(60)
        var yesterday = makeJob(state: .done)
        yesterday.finishedAt = startOfDay.addingTimeInterval(-60)
        for job in [running, today, yesterday] {
            try await store.save(job)
        }

        let ids = Set(try await store.jobsUnfinishedOrFinished(since: startOfDay).map(\.id))
        #expect(ids == [running.id, today.id])
    }

    @Test func committedSpendCountsTodayAndTheQueueInOneUnit() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 86_400 * 100 + 3600)
        let running = makeJob(state: .processing)
        let other = makeJob(state: .queued)
        var today = makeJob(state: .done)
        today.finishedAt = now.addingTimeInterval(-60)
        var yesterday = makeJob(state: .done)
        yesterday.finishedAt = now.addingTimeInterval(-86_400)
        for job in [running, other, today, yesterday] {
            try await store.save(job)
        }

        let all = try await store.committedSpend(on: now, in: .credits, calendar: calendar)
        let withoutOther = try await store.committedSpend(
            on: now, in: .credits, excluding: other.id, calendar: calendar)
        let usd = try await store.committedSpend(on: now, in: .usd, calendar: calendar)
        #expect(all == 36)
        #expect(withoutOther == 24)
        #expect(usd == 0)
    }

    @Test func finishedNewestFirstListsTerminalJobs() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let first = makeJob(createdAt: base, state: .done)
        let second = makeJob(createdAt: base.addingTimeInterval(60), state: .rejected)
        let running = makeJob(createdAt: base.addingTimeInterval(120), state: .processing)
        for job in [first, running, second] {
            try await store.save(job)
        }

        let records = try ModelContext(container).fetch(JobRecord.finishedNewestFirst)
        #expect(records.map(\.id) == [second.id, first.id])
    }

    @Test func problemsAreFailedRejectedAndCanceledNewestFinishedFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func finished(_ state: JobState, minutes: Double) -> Job {
            var job = makeJob(createdAt: base, state: state)
            job.finishedAt = base.addingTimeInterval(minutes * 60)
            return job
        }
        let cleared = finished(.failed(reason: .message("x")), minutes: 1)
        let failed = finished(.failed(reason: .message("x")), minutes: 3)
        let canceled = finished(.canceled, minutes: 4)
        let rejected = finished(.rejected, minutes: 5)
        let done = finished(.done, minutes: 6)
        let running = makeJob(createdAt: base, state: .processing)
        for job in [cleared, done, failed, running, rejected, canceled] {
            try await store.save(job)
        }

        let context = ModelContext(container)
        let after = base.addingTimeInterval(2 * 60)
        let all = try context.fetch(JobRecord.problemsNewestFirst(finishedAfter: after, limit: 10))
        #expect(all.map(\.id) == [rejected.id, canceled.id, failed.id])
        let limited = try context.fetch(JobRecord.problemsNewestFirst(finishedAfter: nil, limit: 2))
        #expect(limited.map(\.id) == [rejected.id, canceled.id])
    }

    @Test func doneJobsAreNewestFirstAndLimited() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let older = makeJob(createdAt: base, state: .done)
        let newer = makeJob(createdAt: base.addingTimeInterval(60), state: .done)
        let newest = makeJob(createdAt: base.addingTimeInterval(120), state: .done)
        let failed = makeJob(createdAt: base.addingTimeInterval(180), state: .failed(reason: .message("x")))
        for job in [older, failed, newest, newer] {
            try await store.save(job)
        }

        #expect(try await store.doneJobs(limit: 2).map(\.id) == [newest.id, newer.id])
    }

    @Test func deletesJob() async throws {
        let job = makeJob()
        try await store.save(job)
        try await store.delete(id: job.id)
        try await store.delete(id: job.id)

        #expect(try await store.job(id: job.id) == nil)
        #expect(try await store.activeJobs().isEmpty)
    }

    @Test func uploadCacheFiltersByDate() async throws {
        let uploadedAt = Date(timeIntervalSince1970: 1_000_000)
        let asset = RemoteAsset(url: URL(string: "https://cdn.example.com/a.mp4")!, id: "media-1")
        try await store.store(asset, contentHash: "abc", uploadedAt: uploadedAt)

        #expect(try await store.asset(forContentHash: "abc", uploadedAfter: uploadedAt) == asset)
        #expect(try await store.asset(forContentHash: "abc", uploadedAfter: uploadedAt.addingTimeInterval(-1)) == asset)
        #expect(try await store.asset(forContentHash: "abc", uploadedAfter: uploadedAt.addingTimeInterval(1)) == nil)
        #expect(try await store.asset(forContentHash: "other", uploadedAfter: .distantPast) == nil)
    }

    @Test func uploadCacheReplacesAssetForSameHash() async throws {
        let first = RemoteAsset(url: URL(string: "https://cdn.example.com/1.mp4")!)
        let second = RemoteAsset(url: URL(string: "https://cdn.example.com/2.mp4")!, id: "media-2")
        try await store.store(first, contentHash: "abc", uploadedAt: Date(timeIntervalSince1970: 1))
        try await store.store(second, contentHash: "abc", uploadedAt: Date(timeIntervalSince1970: 2))

        #expect(try await store.asset(forContentHash: "abc", uploadedAfter: .distantPast) == second)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<AssetRecord>()) == 1)
    }

    @Test func removingOldAssetsKeepsTheOnesUploadedSince() async throws {
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        let old = RemoteAsset(url: URL(string: "https://cdn.example.com/old.mp4")!)
        let fresh = RemoteAsset(url: URL(string: "https://cdn.example.com/fresh.mp4")!)
        try await store.store(old, contentHash: "old", uploadedAt: cutoff.addingTimeInterval(-1))
        try await store.store(fresh, contentHash: "fresh", uploadedAt: cutoff)

        try await store.removeAssets(uploadedBefore: cutoff)

        #expect(try await store.asset(forContentHash: "old", uploadedAfter: .distantPast) == nil)
        #expect(try await store.asset(forContentHash: "fresh", uploadedAfter: .distantPast) == fresh)
    }
}
