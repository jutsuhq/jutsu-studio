import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct OldDraftsTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day: TimeInterval = 86_400
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    func job(
        draft: Bool = true, state: JobState = .done, finishedAt: Date?, createdAt: Date? = nil,
        file: String? = "/results/a.mp4"
    ) -> Job {
        let source = SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 10,
            pixelSize: PixelSize(width: 1280, height: 720), range: 0...10)
        let spec = JobSpec(mode: .motionTransfer, source: source, references: [], resolution: .p480, isDraft: draft)
        var job = Job(spec: spec, providerKind: .apiKey, cost: .usd(1, isEstimate: false), createdAt: createdAt ?? now)
        job.state = state
        job.finishedAt = finishedAt
        job.outputFile = file.map { URL(fileURLWithPath: $0) }
        return job
    }

    func select(_ jobs: [Job], days: Int = 30, missing: Set<String> = []) -> [OldDraft] {
        OldDrafts.select(jobs, olderThan: days, now: now, calendar: calendar) { url in
            missing.contains(url.path) ? nil : 1_000
        }
    }

    @Test func picksOnlyOldFinishedDraftsWithTheirFileOnDisk() {
        let old = job(finishedAt: now - 31 * day, file: "/results/old.mp4")
        let jobs = [
            old,
            job(finishedAt: now - 29 * day, file: "/results/recent.mp4"),
            job(draft: false, finishedAt: now - 60 * day, file: "/results/final.mp4"),
            job(finishedAt: now - 60 * day, file: "/results/gone.mp4"),
            job(finishedAt: now - 60 * day, file: nil),
            job(state: .processing, finishedAt: nil, createdAt: now - 60 * day, file: "/results/active.mp4"),
        ]
        let drafts = select(jobs, missing: ["/results/gone.mp4"])
        #expect(drafts == [OldDraft(jobID: old.id, file: URL(fileURLWithPath: "/results/old.mp4"), bytes: 1_000)])
    }

    @Test func aJobWithoutAFinishDateAgesFromItsCreation() {
        let jobs = [job(state: .failed(reason: .message("x")), finishedAt: nil, createdAt: now - 8 * day)]
        #expect(select(jobs, days: 7).count == 1)
        #expect(select(jobs, days: 30).isEmpty)
    }

    @Test func confirmationCountsDraftsAndSumsTheirSize() throws {
        try CostText.$locale.withValue(.enUS) {
            let drafts = [
                OldDraft(jobID: UUID(), file: URL(fileURLWithPath: "/a.mp4"), bytes: 1_200_000_000),
                OldDraft(jobID: UUID(), file: URL(fileURLWithPath: "/b.mp4"), bytes: 230_000_000),
            ]
            let confirmation = try #require(OldDrafts.confirmation(drafts, days: 30))
            #expect(confirmation.title == "Move 2 drafts to the Trash?")
            #expect(confirmation.message.hasPrefix("2 drafts older than 30 days, 1.43 GB in total."))
            #expect(OldDrafts.confirmation(Array(drafts.prefix(1)), days: 7)?.title == "Move 1 draft to the Trash?")
            #expect(OldDrafts.confirmation([], days: 30) == nil)
            #expect(OldDrafts.summary(drafts) == "2 drafts · 1.43 GB")
            #expect(OldDrafts.summary([]) == "None")
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct StorageUsageTests {
    @Test func countsOnlyResultFilesOnDiskAndEachFolderApart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        let sources = root.appendingPathComponent("sources")
        let cache = root.appendingPathComponent("cache")
        let clips = root.appendingPathComponent("motion-library")
        let uploads = root.appendingPathComponent("account-media")
        for folder in [output, sources, cache, clips, uploads] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let result = output.appendingPathComponent("a.mp4")
        try Data(count: 1_000).write(to: result)
        try Data(count: 5_000).write(to: output.appendingPathComponent("not-in-library.mp4"))
        try Data(count: 200).write(to: sources.appendingPathComponent("s.mp4"))
        try Data(count: 30).write(to: cache.appendingPathComponent("p.jpg"))
        try Data(count: 400).write(to: clips.appendingPathComponent("clip.mp4"))
        try Data(count: 6).write(to: uploads.appendingPathComponent("face.png"))

        let usage = await StorageUsage.measure(
            results: [result, result, output.appendingPathComponent("trashed.mp4")], sources: sources, cache: cache,
            media: [clips, uploads, root.appendingPathComponent("missing")])
        #expect(usage == StorageUsage(results: 1_000, resultCount: 1, sources: 200, cache: 30, media: 406))
        #expect(usage.cacheBytes == 636)
        #expect(usage.resultsText == "1 KB · 1 file")
    }

    @Test func findReadsRealFileSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("draft.mp4")
        try Data(count: 777).write(to: file)
        let source = SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 10,
            pixelSize: PixelSize(width: 1280, height: 720), range: 0...10)
        let spec = JobSpec(mode: .motionTransfer, source: source, references: [], resolution: .p480, isDraft: true)
        let now = Date()
        var job = Job(spec: spec, providerKind: .apiKey, cost: .usd(1, isEstimate: false), createdAt: now - 40 * 86_400)
        job.state = .done
        job.outputFile = file

        let drafts = await OldDrafts.find([job], olderThan: 30, now: now)
        #expect(drafts.map(\.bytes) == [777])
        #expect(StorageUsage(results: 0, resultCount: 0, sources: 0, cache: 0, media: 0).resultsText == "Empty")
    }
}
