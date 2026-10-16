import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Finalize in 1080p of a native Seedance draft on the account (issue #115).
@Suite struct FinalizeTests {
    static let now = JobFixture.now
    static let day: TimeInterval = 24 * 60 * 60

    /// A native draft the account `owner-1` made, completed `daysAgo` days before `now`.
    static func draft(
        daysAgo: Double = 2, kind: ProviderKind = .account, owner: String = "owner-1", isNative: Bool = true
    ) -> Job {
        var spec = JobSpec(
            mode: .motionTransfer, model: .seedance25, source: nil, prompt: "a fox", resolution: .p480,
            isDraft: true, length: 15, aspectRatio: .portrait)
        spec.variants = 1
        var job = Job(spec: spec, providerKind: kind, owner: owner, cost: .credits(45, isEstimate: false))
        job.state = .done
        var remote = RemoteJob(requestID: "draft-job")
        remote.isNativeDraft = isNative
        job.remote = remote
        job.chargedAt = now.addingTimeInterval(-daysAgo * day)
        job.finishedAt = now.addingTimeInterval(-daysAgo * day + 60)
        return job
    }

    @Test func theWindowIsSevenDaysFromCompletion() {
        let job = Self.draft(daysAgo: 2)
        #expect(job.finalizeDeadline == Self.now.addingTimeInterval(5 * Self.day))
        // Without Higgsfield's completion time, the job's own finish counts.
        var unknown = job
        unknown.chargedAt = nil
        #expect(unknown.finalizeDeadline == job.finishedAt?.addingTimeInterval(7 * Self.day))
    }

    @Test func theWindowShowsItsEnd() throws {
        let deadline = try #require(Self.draft().finalizeDeadline)
        #expect(FinalizeText.window(deadline: deadline, now: Self.now).hasPrefix("Finalize in 1080p until"))
        #expect(
            FinalizeText.window(deadline: deadline, now: deadline.addingTimeInterval(1))
                .hasPrefix("The 1080p finalize ended"))
    }

    @Test func aDraftOfTheAccountWithinSevenDaysIsOffered() throws {
        let spec = try #require(Self.draft(daysAgo: 6.9).finalizeSpec(owner: "owner-1", now: Self.now))
        #expect(spec.draftJobID == "draft-job")
        #expect(spec.resolution == .p1080)
        #expect(!spec.isDraft)
        #expect(spec.prompt == "a fox" && spec.length == 15)
    }

    @Test(arguments: [
        (draft(daysAgo: 7.1), "owner-1"), (draft(), "owner-2"), (draft(), nil),
        (draft(kind: .apiKey), "owner-1"), (draft(isNative: false), "owner-1"),
    ])
    func otherDraftsAreNotOffered(job: Job, owner: String?) {
        #expect(job.finalizeSpec(owner: owner, now: Self.now) == nil)
    }

    @Test func aFinishedFinalIsNoDraftToFinalize() {
        var final = Self.draft()
        final.spec.isDraft = false
        #expect(final.finalizeDeadline == nil)
    }

    /// Render final at 1080p is the finalize; at 720p, or for another account, the inputs render again.
    @Test func theFinalAt1080pIsTheFinalize() {
        let item = LibraryItemModel(job: Self.draft(), isStarred: true)
        #expect(item.finalSpec(at: .p1080, owner: "owner-1", now: Self.now).draftJobID == "draft-job")
        #expect(item.finalSpec(at: .p720, owner: "owner-1", now: Self.now) == item.finalSpec(at: .p720))
        #expect(item.finalSpec(at: .p1080, owner: "owner-2", now: Self.now) == item.finalSpec(at: .p1080))
        #expect(item.finalSpec(at: .p1080).draftJobID == nil)

        let finals = BatchFinals([item]).finals(at: .p1080, owner: "owner-1", now: Self.now)
        #expect(finals.map(\.spec.draftJobID) == ["draft-job"])
        #expect(finals.map(\.parentID) == [item.id])
    }

    /// A native draft imported from the account's history is offered within seven days of its `createdAt`.
    @Test func aDraftFromHistoryIsOfferedWithinItsSevenDays() throws {
        var item = HistoryItem(
            id: "draft-job", mode: .motionTransfer, model: .seedance25,
            createdAt: Self.now.addingTimeInterval(-Self.day),
            outputURL: try #require(URL(string: "https://example.com/draft.mp4")), duration: 15, resolution: .p480,
            prompt: "a fox", inputs: RemoteInputs(video: nil, images: []))
        item.isNativeDraft = true
        let job = Job(importing: item, owner: "owner-1", importedAt: Self.now)
        #expect(job.finalizeDeadline == item.createdAt.addingTimeInterval(Job.finalizeWindow))
        #expect(job.finalizeSpec(owner: "owner-1", now: Self.now)?.draftJobID == "draft-job")
        #expect(job.finalizeSpec(owner: "owner-1", now: Self.now.addingTimeInterval(7 * Self.day)) == nil)
        // Before it is downloaded, the history item renders no final of its own.
        #expect(!LibraryItemModel(history: item).canRenderFinal)
        #expect(LibraryItemModel(job: job).canRenderFinal)
    }

    @Test func aStoredRemoteJobWithoutTheFlagDecodes() throws {
        let data = Data(#"{"requestID":"job-1"}"#.utf8)
        #expect(try !JSONDecoder().decode(RemoteJob.self, from: data).isNativeDraft)
        var remote = RemoteJob(requestID: "job-1")
        remote.isNativeDraft = true
        let decoded = try JSONDecoder().decode(RemoteJob.self, from: JSONEncoder().encode(remote))
        #expect(decoded.isNativeDraft)
    }
}
