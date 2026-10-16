import Foundation
import JutsuCore
import Testing

@testable import Presentation

enum TimingFixture {
    /// `JobFixture.job` with the API timings filled in: submitted 4 min ago unless given.
    static func job(
        _ state: JobState, submittedMinutesAgo: Double = 4, queueWait: TimeInterval = 10,
        processing: TimeInterval? = nil
    ) -> Job {
        var job = JobFixture.job(state, createdMinutesAgo: submittedMinutesAgo + 1)
        let submittedAt = JobFixture.now.addingTimeInterval(-submittedMinutesAgo * 60)
        job.submittedAt = submittedAt
        if let processing {
            job.processingAt = submittedAt.addingTimeInterval(queueWait)
            job.chargedAt = submittedAt.addingTimeInterval(queueWait + processing)
        }
        return job
    }

    static func history(processing: TimeInterval, count: Int = 3) -> [Job] {
        (0..<count).map { _ in job(.done, submittedMinutesAgo: 60, processing: processing) }
    }

    static let twoMinutes = GenerationTimes.Estimate(queueWait: 20, processing: 100, sampleCount: 4)
}

@Suite struct TimeEstimateTests {
    @Test func generatingJobFillsTheBarAgainstTheTypicalTime() throws {
        let job = TimingFixture.job(.processing, submittedMinutesAgo: 1)
        let row = JobRowModel(job, now: JobFixture.now, typical: TimingFixture.twoMinutes)
        let estimate = try #require(row.timeEstimate)
        #expect(estimate.label == "usually ~2 min")
        #expect(estimate.fraction == 0.5)
        #expect(!estimate.isOverdue)
        #expect(estimate.help == "Estimate from 4 past jobs")
        #expect(row.progress == nil)
        #expect(row.progressText == nil)
    }

    @Test func pastTheEstimateTheBarStaysFull() throws {
        let job = TimingFixture.job(.processing, submittedMinutesAgo: 5)
        let estimate = try #require(
            JobRowModel(job, now: JobFixture.now, typical: TimingFixture.twoMinutes).timeEstimate)
        #expect(estimate.label == "taking longer than usual")
        #expect(estimate.fraction == 1)
        #expect(estimate.isOverdue)
    }

    @Test func queuedAtTheAPICountsAsGenerating() {
        let job = TimingFixture.job(.queued, submittedMinutesAgo: 0.5)
        #expect(JobRowModel(job, now: JobFixture.now, typical: TimingFixture.twoMinutes).timeEstimate?.fraction == 0.25)
    }

    @Test(arguments: [JobState.uploading, .waitingForSlot, .downloading, .paused(.byUser), .done])
    func onlyTheGenerateStepHasAnEstimate(state: JobState) {
        let job = TimingFixture.job(state)
        #expect(JobRowModel(job, now: JobFixture.now, typical: TimingFixture.twoMinutes).timeEstimate == nil)
    }

    @Test func theGenerateStepTimesTheGenerationAlone() {
        #expect(
            JobRowModel(TimingFixture.job(.processing, submittedMinutesAgo: 2), now: JobFixture.now).generating
                == "2:00")
        #expect(
            JobRowModel(TimingFixture.job(.queued, submittedMinutesAgo: 0.5), now: JobFixture.now).generating == "0:30")
        #expect(JobRowModel(TimingFixture.job(.downloading), now: JobFixture.now).generating == nil)
        var unsubmitted = TimingFixture.job(.processing)
        unsubmitted.submittedAt = nil
        #expect(JobRowModel(unsubmitted, now: JobFixture.now).generating == nil)
    }

    @Test func withoutHistoryOrSubmitTimeOnlyTheTimerShows() {
        let job = TimingFixture.job(.processing)
        let row = JobRowModel(job, now: JobFixture.now)
        #expect(row.timeEstimate == nil)
        #expect(row.elapsed == "5:00")
        var unsubmitted = job
        unsubmitted.submittedAt = nil
        #expect(JobRowModel(unsubmitted, now: JobFixture.now, typical: TimingFixture.twoMinutes).timeEstimate == nil)
        let zero = GenerationTimes.Estimate(queueWait: 0, processing: 0, sampleCount: 3)
        #expect(JobRowModel.timeEstimate(elapsed: 10, typical: zero) == nil)
    }

    @Test(
        arguments: [
            (0.0, "~10 s"), (24, "~20 s"), (54, "~50 s"), (55, "~1 min"), (100, "~2 min"), (3540, "~59 min"),
            (3600, "~1 h"), (5400, "~1 h 30 min"),
        ] as [(Double, String)])
    func approximateDurations(seconds: Double, text: String) {
        #expect(JobRowModel.approximate(seconds) == text)
    }

    @Test(
        arguments: [
            (40.0, "40 s"), (60, "1 min"), (100, "1 min 40 s"), (3600, "1 h"), (3720, "1 h 2 min"),
        ] as [(Double, String)])
    func spokenDurations(seconds: Double, text: String) {
        #expect(JobRowModel.spoken(seconds) == text)
    }

    @Test func doneNotificationSaysHowLongItTook() throws {
        let done = TimingFixture.job(.done, queueWait: 20, processing: 80)
        let notification = try #require(
            JobNotification.changes(
                from: [done.id: .processing], to: [done], since: .distantPast, preferences: NotificationPreferences()
            ).first)
        #expect(notification.subtitle == "dance · Motion transfer")
        #expect(notification.body == "Generated in 1 min 40 s")
        var untimed = done
        untimed.submittedAt = nil
        #expect(JobNotification.generated(untimed) == nil)
    }

    @Test func menuBarRowsCarryTheEstimate() {
        let times = GenerationTimes(TimingFixture.history(processing: 110))
        let summary = MenuBarSummary(
            jobs: [TimingFixture.job(.processing, submittedMinutesAgo: 1)], connection: .none, now: JobFixture.now,
            times: times)
        #expect(summary.rows.first?.timeEstimate?.label == "usually ~2 min")
    }
}

@MainActor
@Suite struct LiveJobsGenerationTimesTests {
    @Test func historyAndFinishedEventsFeedTheEstimate() {
        let live = LiveJobs()
        let spec = TimingFixture.job(.processing).spec
        live.addHistory(TimingFixture.history(processing: 60, count: 2))
        #expect(live.generationTimes.estimate(for: spec) == nil)
        live.apply(TimingFixture.job(.done, processing: 90))
        #expect(live.generationTimes.estimate(for: spec)?.processing == 60)
        #expect(live.generationTimes.estimate(for: spec)?.sampleCount == 3)
    }

    @Test func seededFinishedJobsCount() {
        let live = LiveJobs(TimingFixture.history(processing: 45))
        #expect(live.generationTimes.estimate(for: TimingFixture.job(.processing).spec)?.processing == 45)
    }

    @Test func activeJobsAddNothing() {
        let live = LiveJobs()
        live.apply(TimingFixture.job(.processing))
        live.addHistory([TimingFixture.job(.queued)])
        #expect(live.generationTimes == GenerationTimes())
    }
}
