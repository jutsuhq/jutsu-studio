import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct JobNotificationTests {
    let since = JobFixture.now.addingTimeInterval(-3600)

    func changes(
        _ previous: [Job], _ current: [Job], preferences: NotificationPreferences = NotificationPreferences()
    ) -> [JobNotification] {
        let states = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.state) })
        return JobNotification.changes(from: states, to: current, since: since, preferences: preferences)
    }

    func moved(_ job: Job, to state: JobState, progress: Double = 0) -> Job {
        var copy = job
        copy.state = state
        copy.progress = progress
        if state.isTerminal { copy.finishedAt = JobFixture.now }
        return copy
    }

    struct Case: Sendable {
        var state: JobState
        var kind: JobNotification.Kind
        var title: String
        var destination: JobNotification.Destination
    }

    @Test(arguments: [
        Case(state: .done, kind: .done, title: "Video ready", destination: .library),
        Case(state: .failed(reason: .message("Bad input")), kind: .failed, title: "Job failed", destination: .queue),
        Case(state: .rejected, kind: .rejected, title: "Job rejected", destination: .queue),
        Case(state: .paused(.insufficientFunds), kind: .paused, title: "Job paused", destination: .queue),
        Case(state: .paused(.connectionNeedsAttention), kind: .paused, title: "Job paused", destination: .queue),
    ])
    func eachNotifyingTransition(_ expected: Case) throws {
        let running = JobFixture.job(.processing, progress: 0.5)
        let posted = changes([running], [moved(running, to: expected.state)])
        let notification = try #require(posted.first)
        #expect(posted.count == 1)
        #expect(notification.jobID == running.id)
        #expect(notification.kind == expected.kind)
        #expect(notification.title == expected.title)
        #expect(notification.destination == expected.destination)
        #expect(notification.subtitle == "dance · Motion transfer")
    }

    @Test func bodyCarriesTheReason() throws {
        let running = JobFixture.job(.processing)
        let failed = try #require(
            changes([running], [moved(running, to: .failed(reason: .message("Bad input")))]).first)
        #expect(failed.body == "Bad input · not charged")
        let done = try #require(changes([running], [moved(running, to: .done)]).first)
        #expect(done.body.isEmpty)
    }

    @Test func onlyAVideoReadyCarriesTheResultFile() throws {
        var running = JobFixture.job(.processing)
        running.outputFile = URL(fileURLWithPath: "/tmp/dance.mp4")
        let done = try #require(changes([running], [moved(running, to: .done)]).first)
        #expect(done.resultFile == URL(fileURLWithPath: "/tmp/dance.mp4"))
        let failed = try #require(
            changes([running], [moved(running, to: .failed(reason: .message("Bad input")))]).first)
        #expect(failed.resultFile == nil)
    }

    @Test func aBatchSharesOneThread() throws {
        var running = JobFixture.job(.processing)
        #expect(try #require(changes([running], [moved(running, to: .done)]).first).threadID == nil)
        let batch = UUID()
        running.batchID = batch
        #expect(try #require(changes([running], [moved(running, to: .done)]).first).threadID == batch.uuidString)
    }

    @Test func progressAndInFlightChangesPostNothing() {
        let job = JobFixture.job(.uploading, progress: 0.1)
        #expect(changes([job], [moved(job, to: .uploading, progress: 0.9)]).isEmpty)
        #expect(changes([job], [moved(job, to: .processing)]).isEmpty)
        #expect(changes([job], [moved(job, to: .canceled)]).isEmpty)
    }

    @Test func sameKindTwiceIsNoDuplicate() {
        let done = moved(JobFixture.job(.processing), to: .done)
        #expect(changes([done], [done]).isEmpty)
        let paused = JobFixture.job(.paused(.insufficientFunds))
        #expect(changes([paused], [moved(paused, to: .paused(.connectionNeedsAttention))]).isEmpty)
    }

    @Test func pausesByTheUserPostNothingButTheirSystemPauseDoes() {
        let waiting = JobFixture.job(.waitingForSlot)
        #expect(changes([waiting], [moved(waiting, to: .paused(.byUser))]).isEmpty)
        let held = JobFixture.job(.paused(.byUser))
        #expect(changes([held], [moved(held, to: .paused(.connectionNeedsAttention))]).map(\.kind) == [.paused])
    }

    @Test func disabledSettingPostsNothing() {
        let running = JobFixture.job(.processing)
        #expect(changes([running], [moved(running, to: .done)], preferences: .off).isEmpty)
        #expect(changes([running], [moved(running, to: .rejected)], preferences: .off).isEmpty)
    }

    @Test func doneAndProblemsAreSeparateSwitches() {
        let running = JobFixture.job(.processing)
        let onlyDone = NotificationPreferences(onDone: true, onProblems: false)
        let onlyProblems = NotificationPreferences(onDone: false, onProblems: true)
        let problems: [JobState] = [.failed(reason: .message("x")), .rejected, .paused(.insufficientFunds)]

        #expect(changes([running], [moved(running, to: .done)], preferences: onlyDone).map(\.kind) == [.done])
        #expect(changes([running], [moved(running, to: .done)], preferences: onlyProblems).isEmpty)
        for state in problems {
            #expect(changes([running], [moved(running, to: state)], preferences: onlyDone).isEmpty)
            #expect(changes([running], [moved(running, to: state)], preferences: onlyProblems).count == 1)
        }
    }

    @Test func soundFollowsTheSetting() {
        let running = JobFixture.job(.processing)
        let quiet = NotificationPreferences(playsSound: false)
        #expect(changes([running], [moved(running, to: .done)]).map(\.playsSound) == [true])
        #expect(changes([running], [moved(running, to: .done)], preferences: quiet).map(\.playsSound) == [false])
    }

    @Test func unseenJobsNotifyOnlyIfTheyFinishedWhileObserving() {
        let stored = JobFixture.job(.done, createdMinutesAgo: 300, finishedMinutesAgo: 120)
        let fresh = JobFixture.job(.failed(reason: .message("x")), finishedMinutesAgo: 1)
        let restoredPause = JobFixture.job(.paused(.insufficientFunds))
        let posted = changes([], [stored, fresh, restoredPause])
        #expect(posted.map(\.jobID) == [fresh.id])
    }

    @Test func retriedJobNotifiesAgain() {
        let running = JobFixture.job(.processing)
        var tracker = JobTransitionTracker(since: since)
        let all = NotificationPreferences()
        #expect(tracker.update([running], preferences: all).isEmpty)
        #expect(tracker.update([moved(running, to: .failed(reason: .message("x")))], preferences: all).count == 1)
        #expect(tracker.update([moved(running, to: .failed(reason: .message("x")))], preferences: all).isEmpty)
        #expect(tracker.update([moved(running, to: .queued)], preferences: all).isEmpty)
        #expect(tracker.update([moved(running, to: .done)], preferences: all).map(\.kind) == [.done])
    }

    @Test func trackerRemembersWhileDisabled() {
        let running = JobFixture.job(.processing)
        var tracker = JobTransitionTracker(since: since)
        _ = tracker.update([running], preferences: NotificationPreferences())
        #expect(tracker.update([moved(running, to: .done)], preferences: .off).isEmpty)
        #expect(tracker.update([moved(running, to: .done)], preferences: NotificationPreferences()).isEmpty)
    }

    @Test func userInfoRoundTrips() throws {
        let running = JobFixture.job(.processing)
        let notification = try #require(changes([running], [moved(running, to: .done)]).first)
        let info: [AnyHashable: Any] = notification.userInfo
        let target = try #require(JobNotification.target(of: info))
        #expect(target.jobID == running.id)
        #expect(target.destination == .library)
        #expect(JobNotification.target(of: ["jobID": "nope", "destination": "queue"]) == nil)
        #expect(JobNotification.target(of: [:]) == nil)
    }
}

@Suite struct BackgroundPolicyTests {
    @Test func keepsRunningOnlyWithActiveJobs() {
        #expect(!BackgroundPolicy.keepsRunning(activeCount: 0))
        #expect(BackgroundPolicy.keepsRunning(activeCount: 1))
    }

    @Test func activityIsHeldWhileSomethingRuns() {
        #expect(!BackgroundPolicy.needsActivity([]))
        #expect(!BackgroundPolicy.needsActivity([JobFixture.job(.done), JobFixture.job(.paused(.insufficientFunds))]))
        #expect(BackgroundPolicy.needsActivity([JobFixture.job(.waitingForSlot)]))
    }

    @Test func dockBadge() {
        #expect(BackgroundPolicy.dockBadge(activeCount: 0) == nil)
        #expect(BackgroundPolicy.dockBadge(activeCount: 3) == "3")
    }

    @Test func quitPrompt() {
        #expect(BackgroundPolicy.quitPrompt(activeCount: 0) == nil)
        #expect(
            BackgroundPolicy.quitPrompt(activeCount: 1)
                == QuitPrompt(message: "1 job is still running.", detail: "It resumes on next launch."))
        #expect(
            BackgroundPolicy.quitPrompt(activeCount: 4)
                == QuitPrompt(message: "4 jobs are still running.", detail: "They resume on next launch."))
        #expect(BackgroundPolicy.quitPrompt(activeCount: 4, reason: .user) != nil)
    }

    @Test func quitPromptSaysAJobIsBeingSubmitted() {
        #expect(
            BackgroundPolicy.quitPrompt(activeCount: 1, submittingCount: 1)
                == QuitPrompt(
                    message: "1 job is still running.",
                    detail: "It is being sent to Higgsfield right now, so quitting waits up to 5 seconds "
                        + "for Higgsfield to answer. It resumes on next launch."))
        #expect(
            BackgroundPolicy.quitPrompt(activeCount: 3, submittingCount: 1)?.detail
                == "1 of them is being sent to Higgsfield right now, so quitting waits up to 5 seconds "
                + "for Higgsfield to answer. They resume on next launch.")
        #expect(
            BackgroundPolicy.quitPrompt(activeCount: 3, submittingCount: 2)?.detail.hasPrefix(
                "2 of them are being sent") == true)
        #expect(BackgroundPolicy.quitPrompt(activeCount: 3, submittingCount: 2, reason: .logOut) == nil)
    }

    @Test func imageWorkKeepsTheAppRunningAndIsAskedAboutOnQuit() {
        let making = ImageWork(running: 1, waiting: 0)
        let sending = ImageWork(running: 2, waiting: 1)
        #expect(BackgroundPolicy.keepsRunning(activeCount: 0, images: making))
        #expect(!BackgroundPolicy.keepsRunning(activeCount: 0, images: .none))

        #expect(
            BackgroundPolicy.quitPrompt(activeCount: 0, images: making)
                == QuitPrompt(
                    message: "1 image request is still running.",
                    detail: "Images still being made are followed again on next launch."))
        #expect(
            BackgroundPolicy.quitPrompt(activeCount: 0, images: sending)?.detail
                == "Quitting waits up to 5 seconds for the ones being sent or saved. "
                + "Images still being made are followed again on next launch.")
        #expect(
            BackgroundPolicy.quitPrompt(activeCount: 1, images: sending)
                == QuitPrompt(
                    message: "1 job is still running.",
                    detail: "It resumes on next launch. 2 image requests are running too. Quitting waits up to 5 "
                        + "seconds for the ones being sent or saved. Images still being made are followed again on "
                        + "next launch."))
        #expect(BackgroundPolicy.quitPrompt(activeCount: 0, images: sending, reason: .logOut) == nil)
    }

    @Test(arguments: [QuitReason.logOut, .restart, .shutDown])
    func systemQuitNeverAsks(reason: QuitReason) {
        #expect(BackgroundPolicy.quitPrompt(activeCount: 3, reason: reason) == nil)
        #expect(BackgroundPolicy.quitPrompt(activeCount: 0, reason: reason) == nil)
    }
}

@Suite struct MenuBarSummaryTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let posix = Locale(identifier: "en_US_POSIX")

    func summary(_ jobs: [Job], _ connection: ConnectionState) -> MenuBarSummary {
        MenuBarSummary(jobs: jobs, connection: connection, now: JobFixture.now, calendar: calendar, locale: posix)
    }

    @Test func statusItemLabelAndCount() {
        #expect(MenuBarSummary.accessibilityLabel(activeCount: 0) == "Jutsu Studio, no active jobs")
        #expect(MenuBarSummary.accessibilityLabel(activeCount: 1) == "Jutsu Studio, 1 active job")
        #expect(MenuBarSummary.accessibilityLabel(activeCount: 2) == "Jutsu Studio, 2 active jobs")
        #expect(MenuBarSummary.countText(activeCount: 3, isShown: true) == "3")
        #expect(MenuBarSummary.countText(activeCount: 3, isShown: false) == nil)
        #expect(MenuBarSummary.countText(activeCount: 0, isShown: true) == nil)
    }

    @Test func emptyQueue() {
        CostText.$locale.withValue(.enUS) {
            let empty = summary([], .apiKey(keyID: "key"))
            #expect(empty.headline == "No jobs in the queue")
            #expect(empty.rows.isEmpty)
            #expect(empty.overflow == nil)
            #expect(empty.balance == "Committed today: $0.00")
        }
    }

    @Test func usdSpendCountsTodayAndTheQueue() {
        CostText.$locale.withValue(.enUS) {
            let jobs = [
                JobFixture.job(.uploading, cost: .usd(Decimal(string: "2.5")!, isEstimate: true), progress: 0.4),
                JobFixture.job(.done, cost: .usd(10, isEstimate: false), finishedMinutesAgo: 5),
                JobFixture.job(
                    .failed(reason: .message("x")), cost: .usd(50, isEstimate: false), finishedMinutesAgo: 5),
            ]
            let result = summary(jobs, .apiKey(keyID: "key"))
            #expect(result.balance == "Committed today: $12.50")
            #expect(result.headline == "1 job in the queue")
            #expect(result.rows.map(\.progressText) == ["40%"])
        }
    }

    @Test func creditsForAnAccount() {
        let known = summary([], .account(AccountInfo(email: "a@b.c", credits: 12_500)))
        #expect(known.balance == "Credits left: 12,500")
        #expect(summary([], .account(AccountInfo())).balance == nil)
        #expect(summary([], .none).balance == nil)
    }

    @Test func creditsGroupWithTheLocaleSeparator() {
        #expect(ConnectionState.grouped(12_500, locale: posix) == "12,500")
        #expect(ConnectionState.grouped(1_234_567, locale: posix) == "1,234,567")
        #expect(ConnectionState.grouped(999, locale: posix) == "999")
        #expect(ConnectionState.grouped(12_500, locale: Locale(identifier: "de_DE")) == "12.500")
    }

    @Test func pausedAndOverflow() {
        let jobs =
            (0..<8).map { JobFixture.job(.queued, createdMinutesAgo: Double($0)) } + [
                JobFixture.job(.paused(.insufficientFunds))
            ]
        let result = summary(jobs, .none)
        #expect(result.headline == "9 jobs in the queue · 1 paused")
        #expect(result.rows.map(\.id) == jobs.prefix(MenuBarSummary.rowLimit).map(\.id))
        #expect(result.overflow == "and 3 more")
    }
}
