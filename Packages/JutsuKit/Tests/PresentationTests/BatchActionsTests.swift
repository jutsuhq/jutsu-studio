import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct BatchCancelTests {
    /// Each job a minute older than the next, so the batch's order never rests on equal timestamps.
    private static func batch(_ jobs: [Job]) -> JobBatch {
        JobBatch(id: UUID(), jobs: jobs)
    }

    private static func job(_ state: JobState, minutesAgo: Double, sent: Bool = false) -> Job {
        var job = JobFixture.job(state, createdMinutesAgo: minutesAgo)
        if sent { job.remote = RemoteJob(requestID: "req-\(minutesAgo)") }
        return job
    }

    @Test func cancelsOnlyWhatCancelingStillSaves() {
        let waiting = Self.job(.waitingForSlot, minutesAgo: 9)
        let queued = Self.job(.queued, minutesAgo: 8, sent: true)
        let paused = Self.job(.paused(.byUser), minutesAgo: 7)
        let processing = Self.job(.processing, minutesAgo: 6, sent: true)
        let downloading = Self.job(.downloading, minutesAgo: 5, sent: true)
        let noDisk = Self.job(.paused(.notEnoughDiskSpace), minutesAgo: 4, sent: true)
        let done = Self.job(.done, minutesAgo: 3, sent: true)
        let cancel = BatchCancel(Self.batch([done, noDisk, downloading, processing, paused, queued, waiting]))
        #expect(cancel.jobs.map(\.id) == [waiting.id, queued.id, paused.id])
        #expect(cancel.submitted == 1)
        #expect(!cancel.isEmpty)
    }

    @Test func nothingLeftToCancel() {
        let cancel = BatchCancel(
            Self.batch([Self.job(.processing, minutesAgo: 2, sent: true), Self.job(.done, minutesAgo: 1)]))
        #expect(cancel.isEmpty)
        #expect(cancel.confirmation == nil)
    }

    @Test func asksOnlyOnceAJobWasSent() {
        let local = BatchCancel(
            Self.batch([Self.job(.preparing, minutesAgo: 2), Self.job(.waitingForSlot, minutesAgo: 1)]))
        #expect(local.confirmation == nil)

        var submitting = Self.job(.waitingForSlot, minutesAgo: 1)
        submitting.submitAttempt = SubmitAttempt(isIdempotent: true)
        let sent = BatchCancel(
            Self.batch([Self.job(.queued, minutesAgo: 3, sent: true), Self.job(.uploading, minutesAgo: 2), submitting]))
        #expect(sent.submitted == 2)
        let confirmation = sent.confirmation
        #expect(confirmation?.title == "Cancel 3 jobs?")
        #expect(confirmation?.confirmTitle == "Cancel 3 Jobs")
        #expect(
            confirmation?.message
                == "2 of them are already with Higgsfield, which is asked to drop them. "
                + "A job it already started can't be canceled and is charged.")

        let one = BatchCancel(Self.batch([Self.job(.queued, minutesAgo: 1, sent: true)]))
        #expect(one.confirmation?.title == "Cancel 1 job?")
        #expect(one.confirmation?.message.hasPrefix("1 of them is already with Higgsfield") == true)
    }

    @Test func outcomeNamesHowManyWereRefused() {
        let refused = UserMessage(title: "Can't cancel", message: "It is already processing.")
        #expect(BatchCancel.outcome(refusals: [], of: 3) == nil)
        #expect(BatchCancel.outcome(refusals: [refused], of: 1) == refused)
        let some = BatchCancel.outcome(refusals: [refused, refused], of: 4)
        #expect(some?.title == "2 of 4 jobs weren't canceled")
        #expect(some?.message == "Can't cancel. It is already processing.")
    }
}

@Suite struct BatchFinalsTests {
    private static func draft(_ preset: String, starred: Bool, isDraft: Bool = true) -> LibraryItemModel {
        var item = LibraryFixture.item(isDraft: isDraft, presetName: preset)
        item.isStarred = starred
        return item
    }

    private static func klingDraft() throws -> LibraryItemModel {
        let json = #"""
            {"mode": "motionTransfer", "model": "klingMotionControl", "references": [], "prompt": "",
             "resolution": "480p", "isDraft": true}
            """#
        let spec = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        var job = Job(spec: spec, providerKind: .apiKey, cost: .usd(1, isEstimate: true), createdAt: JobFixture.now)
        job.state = .done
        var item = LibraryItemModel(job: job)
        item.isStarred = true
        return item
    }

    @Test func takesTheStarredDraftsInOrder() {
        let first = Self.draft("Claymation", starred: true)
        let unstarred = Self.draft("Anime", starred: false)
        let starredFinal = Self.draft("Noir", starred: true, isDraft: false)
        let second = Self.draft("Pixel", starred: true)
        let finals = BatchFinals([first, unstarred, starredFinal, second])
        #expect(finals.drafts.map(\.id) == [first.id, second.id])
        #expect(BatchFinals([unstarred, starredFinal]).isEmpty)
    }

    @Test func eachFinalLinksToItsDraftAtTheOneResolution() {
        let first = Self.draft("Claymation", starred: true)
        let second = Self.draft("Pixel", starred: true)
        let batch = BatchFinals([first, second])
        #expect(batch.resolutions == [.p720, .p1080])
        let finals = batch.finals(at: .p1080)
        #expect(finals.map(\.parentID) == [first.id, second.id])
        #expect(finals.map(\.spec) == [first.finalSpec(at: .p1080), second.finalSpec(at: .p1080)])
        #expect(finals.allSatisfy { !$0.spec.isDraft && $0.spec.resolution == .p1080 })
    }

    @Test func leavesOutAFinalAlreadyQueued() {
        let first = Self.draft("Claymation", starred: true)
        let second = Self.draft("Pixel", starred: true)
        let queued = first.finalSpec(at: .p720)
        let finals = BatchFinals([first, second]).finals(at: .p720) { spec, parent in
            parent == first.id && spec == queued
        }
        #expect(finals.map(\.parentID) == [second.id])
        #expect(BatchFinals([first, second]).finals(at: .p1080) { spec, _ in spec == queued }.count == 2)
    }

    @Test func oldKlingDraftsOfferProOnly() throws {
        let batch = BatchFinals([try Self.klingDraft(), try Self.klingDraft()])
        #expect(batch.resolutions == [.p1080])
        #expect(batch.model == .klingMotionControl)
        #expect(batch.finals(at: .p720).allSatisfy { $0.spec.resolution == .p1080 })
    }

    @Test func totalNeedsEveryPrice() {
        let one = Cost.usd(Decimal(string: "1.5")!, isEstimate: false)
        let two = Cost.usd(2, isEstimate: true)
        #expect(BatchFinals.total([one, two]) == .usd(Decimal(string: "3.5")!, isEstimate: true))
        #expect(BatchFinals.total([one, nil]) == nil)
        #expect(BatchFinals.total([]) == nil)
        #expect(
            BatchFinals.total([.credits(40, isEstimate: true), .credits(40, isEstimate: true)])
                == .credits(80, isEstimate: true))
    }

    @Test func listPriceAddsTheFinalsForAnAPIKeyOnly() throws {
        let pricing = try Pricing.bundled()
        let drafts = [Self.draft("Claymation", starred: true), Self.draft("Pixel", starred: true)]
        let finals = BatchFinals(drafts).finals(at: .p720)
        let each = try pricing.cost(for: finals[0].spec)
        #expect(BatchFinals.listPrice(of: finals, pricing: pricing, connection: .apiKey) == Cost.total([each, each]))
        #expect(BatchFinals.listPrice(of: finals, pricing: pricing, connection: .account) == nil)
        #expect(BatchFinals.listPrice(of: finals, pricing: nil, connection: .apiKey) == nil)
    }

    @Test func overTheCapConfirmationNamesTheTotal() {
        CostText.$locale.withValue(.enUS) {
            let finals = BatchFinals([Self.draft("Claymation", starred: true), Self.draft("Pixel", starred: true)])
                .finals(at: .p1080)
            let total = BatchFinals.total([.usd(6, isEstimate: false), .usd(6, isEstimate: false)])
            guard
                case .confirm(let specs, let confirmation) = SubmitDecision.budgeted(
                    finals.map(\.spec), cost: total, committedToday: 70, cap: .usd(75))
            else {
                Issue.record("expected a confirmation")
                return
            }
            #expect(specs == finals.map(\.spec))
            #expect(
                confirmation.message == "These 2 jobs add $12.00, bringing today to $82.00 against your $75.00 cap.")
        }
    }

    @Test func titlesCountTheFinals() {
        #expect(BatchFinals.title(count: 1) == "Render 1 final")
        #expect(BatchFinals.title(count: 3) == "Render 3 finals")
    }
}
