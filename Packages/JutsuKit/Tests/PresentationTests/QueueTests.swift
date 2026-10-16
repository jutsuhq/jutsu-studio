import Foundation
import JutsuCore
import Testing

@testable import Presentation

enum JobFixture {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func job(
        _ state: JobState, mode: Mode = .motionTransfer, kind: ProviderKind = .apiKey,
        cost: Cost = .usd(Decimal(string: "8.168")!, isEstimate: false), createdMinutesAgo: Double = 3,
        finishedMinutesAgo: Double? = nil, progress: Double = 0
    ) -> Job {
        let spec = JobSpec(
            mode: mode,
            source: SourceClip(
                fileURL: URL(fileURLWithPath: "/clips/dance.mov"), duration: 30,
                pixelSize: PixelSize(width: 1280, height: 720), range: 0...12),
            resolution: .p720)
        var job = Job(
            spec: spec, providerKind: kind, cost: cost, createdAt: now.addingTimeInterval(-createdMinutesAgo * 60))
        job.state = state
        job.progress = progress
        job.finishedAt = finishedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }
        return job
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LiveJobsTests {
    @Test func activeIsOldestFirstAndPausedCounts() {
        let newer = JobFixture.job(.processing, createdMinutesAgo: 1)
        let older = JobFixture.job(.paused(.insufficientFunds), createdMinutesAgo: 5)
        let done = JobFixture.job(.done, createdMinutesAgo: 10)
        let live = LiveJobs([newer, done, older])
        #expect(live.active.map(\.id) == [older.id, newer.id])
        #expect(live.activeCount == 2)
    }

    @Test func applyReplacesByID() {
        var job = JobFixture.job(.uploading, progress: 0.2)
        let live = LiveJobs([job])
        job.progress = 0.6
        live.apply(job)
        #expect(live.job(job.id)?.progress == 0.6)
        job.state = .done
        live.apply(job)
        #expect(live.active.isEmpty)
        #expect(live.recentFinished(limit: 5).map(\.id) == [job.id])
    }

    @Test func seedNeverOverwritesANewerEvent() {
        var job = JobFixture.job(.queued)
        let live = LiveJobs()
        job.state = .processing
        live.apply(job)
        job.state = .queued
        live.seed([job])
        #expect(live.job(job.id)?.state == .processing)
    }

    @Test func recentFinishedIsNewestFirstAndLimited() {
        let jobs = [5.0, 1, 3, 9].map { JobFixture.job(.done, createdMinutesAgo: 20, finishedMinutesAgo: $0) }
        let live = LiveJobs(jobs + [JobFixture.job(.queued)])
        #expect(live.recentFinished(limit: 3).map(\.id) == [jobs[1].id, jobs[2].id, jobs[0].id])
        #expect(live.recentFinished(limit: 0).isEmpty)
        #expect(live.recentFinished(limit: 10).count == 4)
    }

    @Test func busySlotsCountQueuedAndProcessing() {
        let live = LiveJobs([
            JobFixture.job(.queued), JobFixture.job(.processing), JobFixture.job(.waitingForSlot),
            JobFixture.job(.downloading), JobFixture.job(.done),
        ])
        #expect(live.busySlots == 2)
        #expect(live.slotsSummary(limit: 3) == "2 of 3 slots busy")
    }

    @Test func submittingCountsJobsWhoseSubmitIsOut() {
        var sending = JobFixture.job(.waitingForSlot)
        sending.submitAttempt = SubmitAttempt(isIdempotent: false)
        var pausedDuringSubmit = JobFixture.job(.paused(.connectionNeedsAttention))
        pausedDuringSubmit.submitAttempt = SubmitAttempt(isIdempotent: true)
        let live = LiveJobs([sending, pausedDuringSubmit, JobFixture.job(.waitingForSlot), JobFixture.job(.queued)])
        #expect(live.submittingCount == 1)
    }

    @Test func pauseAndResumeAllFollowWhatTheyWouldChange() {
        let submitted = LiveJobs([JobFixture.job(.processing), JobFixture.job(.paused(.insufficientFunds))])
        #expect(!submitted.canPauseAll)
        #expect(!submitted.canResumeAll)
        let waiting = LiveJobs([JobFixture.job(.waitingForSlot), JobFixture.job(.paused(.byUser))])
        #expect(waiting.canPauseAll)
        #expect(waiting.canResumeAll)
        #expect(LiveJobs([JobFixture.job(.paused(.connectionNeedsAttention))]).canPauseAll)
    }

    @Test func stateRevisionIgnoresProgress() {
        var job = JobFixture.job(.uploading, progress: 0.2)
        let live = LiveJobs()
        live.apply(job)
        let added = live.stateRevision
        job.progress = 0.6
        live.apply(job)
        #expect(live.stateRevision == added)
        job.state = .queued
        live.apply(job)
        #expect(live.stateRevision == added + 1)
        live.seed([job])
        #expect(live.stateRevision == added + 1)
        live.seed([JobFixture.job(.done)])
        #expect(live.stateRevision == added + 2)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test func oldFinishedKeepsTheNewestTodaysAndActiveOnes() {
        // Today in UTC started 826 minutes before `JobFixture.now`.
        let earlier = [2000.0, 3000, 4000, 5000].map {
            JobFixture.job(.done, createdMinutesAgo: 6000, finishedMinutesAgo: $0)
        }
        let today = JobFixture.job(.failed(reason: .message("Boom")), createdMinutesAgo: 900, finishedMinutesAgo: 10)
        let active = JobFixture.job(.processing, createdMinutesAgo: 9000)

        let old = LiveJobs.oldFinished(
            earlier + [today, active], keeping: 2, now: JobFixture.now, calendar: Self.utc)

        #expect(old == [earlier[1].id, earlier[2].id, earlier[3].id])
    }

    @Test func oldFinishedKeepsABatchWhole() {
        let batchID = UUID()
        var kept = JobFixture.job(.done, createdMinutesAgo: 6000, finishedMinutesAgo: 2000)
        kept.batchID = batchID
        var mate = JobFixture.job(.done, createdMinutesAgo: 6000, finishedMinutesAgo: 3000)
        mate.batchID = batchID
        let alone = JobFixture.job(.done, createdMinutesAgo: 6000, finishedMinutesAgo: 4000)

        let old = LiveJobs.oldFinished([kept, mate, alone], keeping: 1, now: JobFixture.now, calendar: Self.utc)

        #expect(old == [alone.id])
    }

    @Test func aFinishingJobDropsOldFinishedOnes() {
        let limit = LiveJobs.storedFinishedLimit
        let earlier = (0..<limit + 2).map {
            JobFixture.job(.done, createdMinutesAgo: 9000, finishedMinutesAgo: 2000 + Double($0))
        }
        var finishing = JobFixture.job(.downloading, createdMinutesAgo: 1)
        let live = LiveJobs(earlier + [finishing])
        #expect(live.recentFinished(limit: .max).count == limit + 2)

        // Every fixture job finished on a day before the real today.
        finishing.state = .done
        finishing.finishedAt = JobFixture.now
        live.apply(finishing)

        #expect(live.recentFinished(limit: .max).map(\.id) == [finishing.id] + earlier.prefix(limit - 1).map(\.id))
    }

    @Test func consumeAppliesEveryEvent() async {
        let live = LiveJobs()
        let (events, sink) = AsyncStream.makeStream(of: Job.self)
        var job = JobFixture.job(.preparing)
        sink.yield(job)
        job.state = .uploading
        sink.yield(job)
        sink.finish()
        await live.consume(events)
        #expect(live.job(job.id)?.state == .uploading)
        #expect(live.activeCount == 1)
    }
}

@Suite struct JobRowModelTests {
    typealias Role = JobRowModel.ColorRole

    struct Status: Sendable {
        var label: String
        var role: Role
    }

    static let states: [JobState: Status] = [
        .preparing: Status(label: "Preparing", role: .accent), .uploading: Status(label: "Uploading", role: .accent),
        .waitingForSlot: Status(label: "Waiting for slot", role: .info), .queued: Status(label: "Queued", role: .info),
        .processing: Status(label: "Processing", role: .accent),
        .downloading: Status(label: "Downloading", role: .accent),
        .paused(.insufficientFunds): Status(label: "Paused", role: .warning),
        .done: Status(label: "Done", role: .accent),
        .failed(reason: .message("Boom")): Status(label: "Failed", role: .danger),
        .rejected: Status(label: "Rejected", role: .warning), .canceled: Status(label: "Canceled", role: .faint),
    ]

    @Test(arguments: states)
    func statusLabelAndColor(state: JobState, expected: Status) {
        let row = JobRowModel(JobFixture.job(state), now: JobFixture.now)
        #expect(row.statusLabel == expected.label)
        #expect(row.statusRole == expected.role)
        #expect(row.isWorking == (state.isActive && !state.isPaused))
        #expect((row.statusHint != nil) == (state == .waitingForSlot))
    }

    @Test func aJobWaitingForASlotOffersRunNextUntilItsSubmitIsSent() {
        var job = JobFixture.job(.waitingForSlot)
        let cancel = JobRowModel.Action.cancel(isEnabled: true, help: "Cancel, nothing is charged")
        #expect(JobRowModel(job, now: JobFixture.now).actions == [.runNext, cancel])
        job.submitAttempt = SubmitAttempt(isIdempotent: true)
        #expect(JobRowModel(job, now: JobFixture.now).actions == [cancel])
    }

    @Test(arguments: [
        (JobState.preparing, true), (.uploading, true), (.queued, true),
        (.processing, false), (.downloading, true),
    ])
    func runningStatesOfferCancel(state: JobState, enabled: Bool) throws {
        let row = JobRowModel(JobFixture.job(state), now: JobFixture.now)
        #expect(row.actions.count == 1)
        guard case .cancel(let isEnabled, let help) = try #require(row.actions.first) else {
            Issue.record("Expected cancel, got \(row.actions)")
            return
        }
        #expect(isEnabled == enabled)
        #expect(!help.isEmpty)
        #expect(row.note == nil)
    }

    @Test func processingCancelExplainsWhy() {
        let row = JobRowModel(JobFixture.job(.processing), now: JobFixture.now)
        #expect(row.actions == [.cancel(isEnabled: false, help: "Already processing, the API can't cancel it")])
    }

    @Test func downloadingCancelSaysItWasCharged() {
        let row = JobRowModel(JobFixture.job(.downloading), now: JobFixture.now)
        #expect(row.actions == [.cancel(isEnabled: true, help: "Stop the download, the generation is already charged")])
    }

    /// Only a finished row with a saved video drags it out.
    @Test func rowFileIsTheFinishedVideo() {
        let output = URL(fileURLWithPath: "/Movies/out.mp4")
        var done = JobFixture.job(.done)
        done.outputFile = output
        var failed = JobFixture.job(.failed(reason: .message("x")))
        failed.outputFile = output
        #expect(JobRowModel(done, now: JobFixture.now).file == output)
        #expect(JobRowModel(JobFixture.job(.done), now: JobFixture.now).file == nil)
        #expect(JobRowModel(failed, now: JobFixture.now).file == nil)
    }

    @Test func terminalAndPausedActions() {
        let output = URL(fileURLWithPath: "/Movies/out.mp4")
        var done = JobFixture.job(.done)
        done.outputFile = output
        #expect(JobRowModel(done, now: JobFixture.now).actions == [.showInFinder(output), .openInLibrary])
        #expect(JobRowModel(JobFixture.job(.done), now: JobFixture.now).actions == [.openInLibrary])
        #expect(JobRowModel(JobFixture.job(.failed(reason: .message("x"))), now: JobFixture.now).actions == [.retry])
        #expect(JobRowModel(JobFixture.job(.canceled), now: JobFixture.now).actions == [.retry])
        #expect(JobRowModel(JobFixture.job(.rejected), now: JobFixture.now).actions == [.edit])
        for state in [JobState.failed(reason: .message("Download failed")), .canceled] {
            var paid = JobFixture.job(state)
            paid.remote = RemoteJob(requestID: "r1")
            paid.chargedAt = JobFixture.now
            #expect(JobRowModel(paid, now: JobFixture.now).actions == [.retryDownload, .generateAgain])
        }
        var timedOut = JobFixture.job(.failed(reason: .deadline))
        timedOut.remote = RemoteJob(requestID: "r1")
        timedOut.timedOutAt = JobFixture.now
        #expect(JobRowModel(timedOut, now: JobFixture.now).actions == [.checkAgain])
        #expect(
            JobRowModel(JobFixture.job(.paused(.insufficientFunds)), now: JobFixture.now).actions == [
                .resume, .cancel(isEnabled: true, help: "Cancel, nothing is charged"),
            ])
    }

    @Test(arguments: [JobState.failed(reason: .message("Input video could not be downloaded")), .rejected, .canceled])
    func notChargedStatesShowZero(state: JobState) throws {
        try CostText.$locale.withValue(.enUS) {
            let usd = JobRowModel(JobFixture.job(state), now: JobFixture.now)
            #expect(!usd.isCharged)
            #expect(usd.cost == "$0.00")
            #expect(usd.meta.contains(" · $0.00 · "))
            let note = try #require(usd.note)
            #expect(note.text.lowercased().contains("not charged"))
            let credits = JobRowModel(
                JobFixture.job(state, kind: .account, cost: .credits(96, isEstimate: false)), now: JobFixture.now)
            #expect(credits.cost == "0 cr")
        }
    }

    @Test func jobsTheAPIFinishedStayChargedWhenTheDownloadStops() {
        CostText.$locale.withValue(.enUS) {
            var canceled = JobFixture.job(.canceled)
            canceled.chargedAt = JobFixture.now
            let canceledRow = JobRowModel(canceled, now: JobFixture.now)
            #expect(canceledRow.isCharged)
            #expect(canceledRow.cost == "$8.17")
            #expect(canceledRow.note == .init(text: "Download canceled · charged", role: .faint))

            var failed = JobFixture.job(.failed(reason: .message("Download failed")))
            failed.chargedAt = JobFixture.now
            #expect(
                JobRowModel(failed, now: JobFixture.now).note == .init(text: "Download failed · charged", role: .danger)
            )
        }
    }

    @Test func failedAndRejectedNotes() {
        let failed = JobRowModel(
            JobFixture.job(.failed(reason: .message("Input video could not be downloaded"))), now: JobFixture.now)
        #expect(failed.note == .init(text: "Input video could not be downloaded · not charged", role: .danger))
        let blank = JobRowModel(JobFixture.job(.failed(reason: .message(" "))), now: JobFixture.now)
        #expect(blank.note?.text == "Failed · not charged")
        let timedOut = JobRowModel(JobFixture.job(.failed(reason: .deadline)), now: JobFixture.now)
        #expect(
            timedOut.note?.text
                == "Higgsfield didn't finish this job in time. Check the result in your generations on Higgsfield."
                + " · not charged")
        let moderated = JobRowModel(JobFixture.job(.failed(reason: .contentModeration)), now: JobFixture.now)
        #expect(moderated.note?.text == "Rejected by content moderation. · not charged")
        let rejected = JobRowModel(JobFixture.job(.rejected), now: JobFixture.now)
        #expect(rejected.note == .init(text: "Rejected by content moderation · not charged", role: .warning))
        var protected = JobFixture.job(.rejected)
        protected.rejection = .protectedContent
        #expect(
            JobRowModel(protected, now: JobFixture.now).note?.text
                == "Rejected: a recognizable person or protected content · not charged")
    }

    @Test func pausedReasonDependsOnConnection() {
        let apiKey = JobRowModel(JobFixture.job(.paused(.insufficientFunds)), now: JobFixture.now)
        #expect(apiKey.note?.text == "Not enough API balance · top up, then resume")
        let account = JobRowModel(JobFixture.job(.paused(.insufficientFunds), kind: .account), now: JobFixture.now)
        #expect(account.note?.text == "Out of plan credits · top up, then resume")
        let attention = JobRowModel(JobFixture.job(.paused(.connectionNeedsAttention)), now: JobFixture.now)
        #expect(attention.note?.text == "Connection needs attention · sign in again, then resume")
        #expect(attention.note?.role == .warning)
        let byUser = JobRowModel(JobFixture.job(.paused(.byUser)), now: JobFixture.now)
        #expect(byUser.note == .init(text: "Paused by you · nothing is submitted until you resume", role: .faint))
        #expect(byUser.statusLabel == "Paused")
    }

    @Test func jobPausedForDiskSpaceSaysItIsChargedAndResumes() {
        let row = JobRowModel(JobFixture.job(.paused(.notEnoughDiskSpace)), now: JobFixture.now)

        #expect(
            row.note
                == .init(text: "Not enough disk space to save the result · free up space, then resume", role: .warning))
        #expect(
            row.actions == [
                .resume, .cancel(isEnabled: true, help: "Stop the download, the generation is already charged"),
            ])
    }

    @Test func aRetryingJobSaysWhenItTriesAgainAndWhy() {
        var job = JobFixture.job(.uploading)
        job.retrying = RetryStatus(
            failures: 3, since: JobFixture.now.addingTimeInterval(-60),
            nextAttemptAt: JobFixture.now.addingTimeInterval(29.4),
            cause: .server(status: 502))

        let row = JobRowModel(job, now: JobFixture.now)
        #expect(
            row.note
                == .init(
                    text: "Retrying in 30 s · attempt 4 · last error: Higgsfield server error (HTTP 502)",
                    role: .warning))
        #expect(row.statusLabel == "Uploading")
        #expect(row.actions == [.cancel(isEnabled: true, help: "Cancel, nothing is charged")])

        let due = JobRowModel(job, now: JobFixture.now.addingTimeInterval(40))
        #expect(due.note?.text == "Retrying · attempt 4 · last error: Higgsfield server error (HTTP 502)")
        job.retrying?.cause = .network
        #expect(
            JobRowModel(job, now: JobFixture.now).note?.text
                == "Retrying in 30 s · attempt 4 · last error: no connection to Higgsfield")
        #expect(JobRowModel(JobFixture.job(.uploading), now: JobFixture.now).note == nil)
    }

    @Test func aJobPausedAfterFailingSaysWhyAndResumes() {
        var job = JobFixture.job(.paused(.keptFailing))
        job.retrying = RetryStatus(
            failures: 19, since: JobFixture.now.addingTimeInterval(-900), nextAttemptAt: JobFixture.now,
            cause: .modelUnavailable)

        let row = JobRowModel(job, now: JobFixture.now)
        #expect(
            row.note
                == .init(
                    text: "Kept failing before it was sent (the model is unavailable on Higgsfield) · not charged, "
                        + "resume to try again",
                    role: .warning))
        #expect(row.actions == [.resume, .cancel(isEnabled: true, help: "Cancel, nothing is charged")])
        #expect(
            JobRowModel(JobFixture.job(.paused(.keptFailing)), now: JobFixture.now).note?.text
                == "Kept failing before it was sent · not charged, resume to try again")
    }

    @Test func jobPausedForItsServerPriceAsksBeforeResuming() {
        CostText.$locale.withValue(.enUS) {
            var job = JobFixture.job(.paused(.priceAboveCap))
            job.serverPrice = .usd(9.5, isEstimate: false)
            let row = JobRowModel(job, now: JobFixture.now)

            #expect(row.actions == [.confirmPrice, .cancel(isEnabled: true, help: "Cancel, nothing is charged")])
            #expect(row.note?.text == "Price from Higgsfield goes over today's spending cap · confirm to resume")
            #expect(row.cost == "$9.50")
            #expect(row.priceSource == "Price from Higgsfield")
            #expect(JobRowModel(JobFixture.job(.queued), now: JobFixture.now).priceSource == "Estimate")
        }
    }

    @Test func metaLine() {
        CostText.$locale.withValue(.enUS) {
            let row = JobRowModel(JobFixture.job(.uploading, progress: 0.424), now: JobFixture.now)
            #expect(row.title == "dance · Motion transfer")
            #expect(row.meta == "Motion transfer · 720p · 00:00.0–00:12.0 · $8.17 · 3 min ago")
            #expect(row.progress == 0.424)
            #expect(row.progressText == "42%")
        }
    }

    @Test func metaLineNamesAModelOtherThanGenjutsu() {
        var job = JobFixture.job(.done, kind: .account, cost: .credits(70, isEstimate: false))
        job.spec.model = .seedance25
        #expect(JobRowModel(job, now: JobFixture.now).meta.hasPrefix("Motion transfer · Seedance 2.5 · 720p · "))
    }

    @Test func metaLineWithCreditsAndFinishedTime() {
        CostText.$locale.withValue(.enUS) {
            let job = JobFixture.job(
                .done, mode: .restyle, kind: .account, cost: .credits(96, isEstimate: false), createdMinutesAgo: 300,
                finishedMinutesAgo: 120)
            let row = JobRowModel(job, now: JobFixture.now)
            #expect(row.meta == "Restyle · 720p · 00:00.0–00:12.0 · 96 cr · 2 h ago")
            #expect(row.progress == nil)
            #expect(row.progressText == nil)
        }
    }

    @Test func progressIsClampedAndOnlyForReportingStates() {
        #expect(JobRowModel(JobFixture.job(.downloading, progress: 1.4), now: JobFixture.now).progressText == "100%")
        #expect(JobRowModel(JobFixture.job(.queued, progress: 0.5), now: JobFixture.now).progress == nil)
        #expect(JobRowModel(JobFixture.job(.processing, progress: 0), now: JobFixture.now).progressText == nil)
    }

    @Test func costFormatting() {
        CostText.$locale.withValue(.enUS) {
            #expect(JobRowModel.format(.usd(Decimal(string: "0.318")!, isEstimate: false), charged: true) == "$0.32")
            #expect(JobRowModel.format(.usd(12, isEstimate: true), charged: true) == "~$12.00")
            #expect(JobRowModel.format(.usd(Decimal(string: "3.005")!, isEstimate: false), charged: true) == "$3.01")
            #expect(JobRowModel.format(.credits(1200, isEstimate: false), charged: true) == "1200 cr")
        }
    }

    @Test func timecodes() {
        CostText.$locale.withValue(.enUS) {
            #expect(JobRowModel.timecode(0) == "00:00.0")
            #expect(JobRowModel.timecode(12.04) == "00:12.0")
            #expect(JobRowModel.timecode(59.96) == "01:00.0")
            #expect(JobRowModel.timecode(754.5) == "12:34.5")
        }
    }

    @Test(arguments: [
        (0.0, "just now"), (0.5, "just now"), (3, "3 min ago"), (59, "59 min ago"), (90, "2 h ago"),
        (1439, "24 h ago"), (2880, "2 d ago"),
    ])
    func relativeTime(minutesAgo: Double, expected: String) {
        let date = JobFixture.now.addingTimeInterval(-minutesAgo * 60)
        #expect(JobRowModel.relativeTime(from: date, to: JobFixture.now) == expected)
    }
}

@Suite struct JobRowStageTests {
    typealias Stage = JobRowModel.Stage

    @Test(arguments: [
        (JobState.preparing, Stage?.some(.prepare)), (.uploading, .upload), (.waitingForSlot, .upload),
        (.queued, .generate), (.processing, .generate), (.downloading, .save),
        (.paused(.insufficientFunds), nil), (.done, nil), (.failed(reason: .message("")), nil), (.canceled, nil),
    ])
    func stageFollowsState(_ state: JobState, _ stage: Stage?) {
        #expect(JobRowModel(JobFixture.job(state), now: JobFixture.now).stage == stage)
    }

    @Test func elapsedOnlyWhileActive() {
        #expect(JobRowModel(JobFixture.job(.processing, createdMinutesAgo: 3), now: JobFixture.now).elapsed == "3:00")
        #expect(JobRowModel(JobFixture.job(.done, createdMinutesAgo: 3), now: JobFixture.now).elapsed == nil)
    }

    @Test func aRetryRestartsTheTimer() {
        var job = JobFixture.job(.processing, createdMinutesAgo: 13)
        job.retriedAt = JobFixture.now.addingTimeInterval(-90)
        let row = JobRowModel(job, now: JobFixture.now)
        #expect(row.elapsed == "1:30")
        #expect(row.meta.hasSuffix("2 min ago"))
    }

    @Test func durationFormats() {
        #expect(JobRowModel.duration(42) == "0:42")
        #expect(JobRowModel.duration(725) == "12:05")
        #expect(JobRowModel.duration(3729) == "1:02:09")
    }

    @Test func promptIsOneLineOrNil() {
        var job = JobFixture.job(.processing)
        job.spec.prompt = "  Keep the car\nswap the sky  "
        #expect(JobRowModel(job, now: JobFixture.now).prompt == "Keep the car swap the sky")
        job.spec.prompt = " \n "
        #expect(JobRowModel(job, now: JobFixture.now).prompt == nil)
    }
}
