import Foundation
import JutsuAgent
import JutsuCore
import Testing

@testable import Presentation

@Suite struct MenuBarPanelTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let posix = Locale(identifier: "en_US_POSIX")
    let now = JobFixture.now

    func panel(
        _ jobs: [Job], _ connection: ConnectionState = .none,
        agents: MenuBarPanel.AgentsInput = .init(isAllowed: false),
        runs: [MenuBarPanel.Run] = []
    ) -> MenuBarPanel {
        MenuBarPanel(
            jobs: jobs, runs: runs, connection: connection, agents: agents, now: now, calendar: calendar,
            locale: posix)
    }

    func agentJob(_ state: JobState, minutesAgo: Double = 3) -> Job {
        var job = JobFixture.job(state, createdMinutesAgo: minutesAgo)
        job.agent = AgentOrigin(client: "claude-code", requestID: "r", maxCost: AgentMoney(500, .usdCents))
        return job
    }

    @Test func statusItemLabelAndCount() {
        #expect(MenuBarPanel.accessibilityLabel(activeCount: 0) == "Jutsu Studio, no active jobs")
        #expect(MenuBarPanel.accessibilityLabel(activeCount: 2) == "Jutsu Studio, 2 active jobs")
        #expect(MenuBarPanel.countText(activeCount: 3, isShown: true) == "3")
        #expect(MenuBarPanel.countText(activeCount: 3, isShown: false) == nil)
        #expect(MenuBarPanel.countText(activeCount: 0, isShown: true) == nil)
    }

    @Test func anIdlePanelHasOnlyItsHeader() {
        let idle = panel([])
        #expect(idle.isIdle)
        #expect(idle.header.plate == nil)
        #expect(idle.header.agents.status == "Agents off")
        #expect(idle.today == nil)
    }

    @Test func anAPIKeyShowsWhatIsCommittedToday() {
        CostText.$locale.withValue(.enUS) {
            let jobs = [
                JobFixture.job(.uploading, cost: .usd(Decimal(string: "2.5")!, isEstimate: true), progress: 0.4),
                JobFixture.job(.done, cost: .usd(10, isEstimate: false), finishedMinutesAgo: 5),
                JobFixture.job(
                    .failed(reason: .message("x")), cost: .usd(50, isEstimate: false), finishedMinutesAgo: 5),
            ]
            let result = panel(jobs, .apiKey(keyID: "key"))
            #expect(result.header.spend == "Committed today: $12.50")
            #expect(result.header.plate?.isAPIKey == true)
            #expect(result.running.map(\.progress) == [0.4])
            #expect(result.running.first?.cancel != nil)
        }
    }

    @Test func theHeaderLeavesTodaysSpendToTheCapLine() {
        let budget = AgentCapabilities.Budget(
            unit: .usdCents, dailyLimit: 1000, spentToday: 0, reservedToday: 0, remaining: 1000, dailyCap: 5000,
            capTakenToday: 1250)
        let jobs = [
            JobFixture.job(.done, cost: .usd(Decimal(string: "12.5")!, isEstimate: false), finishedMinutesAgo: 5)
        ]
        let result = panel(jobs, .apiKey(keyID: "key"), agents: .init(isAllowed: true, budget: budget))
        #expect(result.today?.cap != nil)
        #expect(result.header.spend == nil)
    }

    @Test func anAccountShowsItsCredits() {
        let account = panel([], .account(AccountInfo(plan: "Pro", credits: 12_500)))
        #expect(account.header.plate?.amount == "12,500")
        #expect(account.header.spend == nil)
    }

    /// Every pause but the person's own Pause all waits for them; their own pause stays with the running work.
    @Test func creditsGroupWithTheLocaleSeparator() {
        #expect(ConnectionState.grouped(12_500, locale: posix) == "12,500")
        #expect(ConnectionState.grouped(1_234_567, locale: posix) == "1,234,567")
        #expect(ConnectionState.grouped(999, locale: posix) == "999")
        #expect(ConnectionState.grouped(12_500, locale: Locale(identifier: "de_DE")) == "12.500")
    }

    @Test func heldJobsNeedThePersonAndOpenTheirRow() {
        let funds = JobFixture.job(.paused(.insufficientFunds), createdMinutesAgo: 9)
        let held = agentJob(.paused(.agentLimit), minutesAgo: 8)
        let paused = JobFixture.job(.paused(.byUser), createdMinutesAgo: 7)
        let queued = JobFixture.job(.queued, createdMinutesAgo: 6)
        let result = panel([queued, paused, held, funds])
        #expect(result.needsYou.map(\.target) == [.job(funds.id), .job(held.id)])
        #expect(result.running.map(\.id) == [paused.id, queued.id])
        #expect(result.needsYouOverflow == nil)
    }

    @Test func runsFollowThePaidJobsAndOverflow() {
        let jobs = (0..<3).map { JobFixture.job(.queued, createdMinutesAgo: Double(10 - $0)) }
        let runs = (0..<3).map {
            MenuBarPanel.Run(
                id: UUID(), kind: $0 == 0 ? .onDevice : .subtitles, title: "clip \($0)", detail: "Working",
                fraction: 0.5)
        }
        let result = panel(jobs, runs: runs)
        #expect(result.running.count == MenuBarPanel.runningLimit)
        #expect(result.running.map(\.kind) == [.job, .job, .job, .onDevice])
        #expect(result.runningOverflow == "and 2 more")
        #expect(result.running.last?.cancel?.isEnabled == true)
    }

    /// An agent's request for a model download waits in Needs you until it is answered or an hour passes.
    @Test func anAgentsAskOpensTheItemsSheet() {
        let item = UUID()
        var activity = AgentActivity()
        activity.noteAsk(
            .init(item: item, sheet: .upscaleOnMac, title: "rooftop", askedAt: now.addingTimeInterval(-60)))
        let asked = panel([], agents: .init(isAllowed: true, activity: activity))
        #expect(asked.needsYou.map(\.target) == [.sheet(.upscaleOnMac, item: item)])
        #expect(asked.needsYou.first?.title == "rooftop")

        var old = AgentActivity()
        old.noteAsk(.init(item: item, sheet: .subtitles, title: "rooftop", askedAt: now.addingTimeInterval(-7200)))
        #expect(panel([], agents: .init(isAllowed: true, activity: old)).needsYou.isEmpty)
        activity.clearAsk(for: item, sheet: .upscaleOnMac)
        #expect(activity.asks.isEmpty)
    }

    /// An agent asking again replaces its ask; an item can wait in both sheets; old asks go as new ones come.
    @Test func asksAreOnePerItemAndSheetAndExpire() {
        let item = UUID()
        var activity = AgentActivity()
        activity.noteAsk(.init(item: item, sheet: .upscaleOnMac, title: "a", askedAt: now.addingTimeInterval(-60)))
        activity.noteAsk(.init(item: item, sheet: .upscaleOnMac, title: "a", askedAt: now))
        activity.noteAsk(.init(item: item, sheet: .subtitles, title: "a", askedAt: now))
        #expect(activity.asks.map(\.sheet) == [.subtitles, .upscaleOnMac])
        let shown = panel([], agents: .init(isAllowed: true, activity: activity)).needsYou
        #expect(Set(shown.map(\.id)).count == 2)

        var old = AgentActivity()
        old.noteAsk(.init(item: UUID(), sheet: .subtitles, title: "b", askedAt: now.addingTimeInterval(-7200)))
        old.noteAsk(.init(item: item, sheet: .upscaleOnMac, title: "a", askedAt: now))
        #expect(old.asks.map(\.item) == [item])
        old.clearAsk(for: item, sheet: .subtitles)
        #expect(old.asks.count == 1)
    }

    @Test func theHeaderSaysWhichAgentsAreConnected() {
        var activity = AgentActivity()
        #expect(
            panel([], agents: .init(isAllowed: true, activity: activity)).header.agents.status == "No agent connected")
        activity.noteRequest(from: "claude-code", at: now.addingTimeInterval(-120))
        #expect(
            panel([], agents: .init(isAllowed: true, activity: activity)).header.agents.status
                == "claude-code connected")
        activity.noteRequest(from: nil, at: now.addingTimeInterval(-30))
        activity.noteRequest(from: "codex", at: now.addingTimeInterval(-3600))
        #expect(
            panel([], agents: .init(isAllowed: true, activity: activity)).header.agents.status
                == "2 agents connected")
    }

    @Test func aClientsRequestsAreNotedOncePerMinute() {
        var activity = AgentActivity()
        activity.noteRequest(from: "claude-code", at: now)
        let noted = activity
        activity.noteRequest(from: "claude-code", at: now.addingTimeInterval(30))
        #expect(activity == noted)
        activity.noteRequest(from: "claude-code", at: now.addingTimeInterval(61))
        #expect(activity.lastRequest["claude-code"] == now.addingTimeInterval(61))
    }

    /// Pause agents shows while an agent's job can still be stopped before its submit, Resume agents once the
    /// agents' jobs are paused.
    @Test func pauseAndResumeAgentsFollowTheAgentsJobs() {
        let agents = MenuBarPanel.AgentsInput(isAllowed: true)
        #expect(panel([JobFixture.job(.queued)], agents: agents).header.agents.control == nil)
        #expect(panel([agentJob(.waitingForSlot)], agents: agents).header.agents.control == .pause)
        #expect(panel([agentJob(.paused(.byUser))], agents: agents).header.agents.control == .resume)
        #expect(panel([agentJob(.paused(.agentLimit))], agents: agents).header.agents.control == nil)
    }

    @Test func todaysBudgetFillsItsBar() throws {
        try CostText.$locale.withValue(.enUS) {
            let budget = AgentCapabilities.Budget(
                unit: .usdCents, dailyLimit: 1000, spentToday: 420, reservedToday: 100, remaining: 480, dailyCap: 5000,
                capTakenToday: 1200)
            let today = try #require(panel([], agents: .init(isAllowed: true, budget: budget)).today)
            #expect(today.spent == "$4.20 spent")
            #expect(today.reserved == "$1.00 reserved")
            #expect(today.limit == "of $10.00")
            #expect(today.remaining == "$4.80 left")
            #expect(today.spentFraction == 0.42)
            #expect(today.reservedFraction == 0.1)
            #expect(!today.isUsedUp)
            #expect(today.cap == "Your daily cap: $12.00 of $50.00")
            #expect(panel([], agents: .init(isAllowed: false, budget: budget)).today == nil)
        }
        let none = AgentCapabilities.Budget(unit: .credits, dailyLimit: 0, spentToday: 0, remaining: 0)
        #expect(panel([], agents: .init(isAllowed: true, budget: none)).today == nil)
        let usedUp = AgentCapabilities.Budget(
            unit: .credits, dailyLimit: 100, spentToday: 80, reservedToday: 40, remaining: 0)
        let full = try #require(panel([], agents: .init(isAllowed: true, budget: usedUp)).today)
        #expect(full.isUsedUp)
        #expect(full.spentFraction + full.reservedFraction <= 1)
    }

    @Test func recentResultsAreTheLastDoneJobs() {
        let jobs = (1...5).map { minutes in
            var job = JobFixture.job(.done, finishedMinutesAgo: Double(minutes))
            job.outputFile = URL(filePath: "/tmp/result-\(minutes).mp4")
            return job
        }
        let failed = JobFixture.job(.failed(reason: .message("x")), finishedMinutesAgo: 0.5)
        let result = panel(jobs + [failed])
        #expect(result.recent.map(\.id) == jobs.prefix(MenuBarPanel.recentLimit).map(\.id))
        #expect(result.recent.first?.detail == "1 min ago")
        #expect(result.recent.first?.file == URL(filePath: "/tmp/result-1.mp4"))
        #expect(!result.isIdle)
    }

    @Test func theIconsProgressMovesInSteps() throws {
        #expect(MenuBarPanel.iconProgress([]) == nil)
        let runs = [0.5, 0.2].map {
            MenuBarPanel.Run(id: UUID(), kind: .onDevice, title: "clip", detail: "", fraction: $0)
        }
        let held = JobFixture.job(.paused(.insufficientFunds))
        // (0 + 0.5 + 0.2) / 3 = 0.233…, down to 2/12; the held job doesn't count.
        let progress = try #require(
            MenuBarPanel.iconProgress(jobs: [JobFixture.job(.queued), held], runs: runs, now: now))
        #expect(abs(progress - 2.0 / 12) < 0.0001)
    }
}
