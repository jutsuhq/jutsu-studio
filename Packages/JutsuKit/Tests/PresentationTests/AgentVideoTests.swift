import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// An agent's video becomes the same job the Create form makes, by the same rules, and is refused where the form
/// would quietly fit it.
@Suite struct AgentVideoOrderTests {
    let context = CreateFixture.apiKey
    let base = CreateForm(mode: .restyle, resolution: .p720)

    func order(
        model: String? = nil, start: TimeInterval? = 1, end: TimeInterval? = 6, images: Int = 1,
        configure: (inout AgentVideoOrder) -> Void = { _ in }
    ) -> AgentVideoOrder {
        var order = AgentVideoOrder(
            mode: "motion_transfer", model: model, prompt: "Image 1 dances",
            source: AgentVideoOrder.Source(video: CreateFixture.video(duration: 14.2), start: start, end: end),
            images: (0..<images).map { LocalImage(fileURL: CreateFixture.image($0)) })
        configure(&order)
        return order
    }

    func refusal(_ order: AgentVideoOrder, in context: CreateContext? = nil) -> String? {
        if case .failure(let refusal) = order.spec(from: base, in: context ?? self.context) {
            refusal.message
        } else {
            nil
        }
    }

    @Test func theJobIsWhatTheCreateFormWouldQueue() throws {
        let spec = try order().spec(from: base, in: context).get()

        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.setSource(CreateFixture.video(duration: 14.2))
        form.ranges = [1...6]
        form.addReferences(CreateFixture.references([CreateFixture.image(0)]))
        form.prompt = "Image 1 dances"
        #expect(form.makeSpecs(isDraft: false, in: context) == [spec])
        #expect(spec.source?.range == 1...6)
        #expect(spec.model == .genjutsu)
    }

    /// The agent's title names the job in the Queue, the Library and export names; the source's name without one.
    @Test func aTitleNamesTheJobInsteadOfTheSourceFile() throws {
        let untitled = try order().spec(from: base, in: context).get()
        #expect(untitled.title == nil)
        let spec = try order { $0.title = "  Knight on the roof\n" }.spec(from: base, in: context).get()
        #expect(spec.title == "Knight on the roof")
        let job = Job(spec: spec, providerKind: .apiKey, cost: .usd(1, isEstimate: true), createdAt: .now)
        #expect(LibraryItemModel(job: job).sourceName == "Knight on the roof")
        #expect(JobRowModel(job, now: .now).title.hasPrefix("Knight on the roof · "))
        #expect(LibraryFilter(query: "roof").matches(LibraryItemModel(job: job)))
    }

    /// The form keeps a range inside the model's window by moving it; an agent's range is refused instead.
    @Test func aRangeOutsideTheModelsWindowIsRefusedNotMoved() throws {
        let limits = VideoModel.genjutsu.limits(for: .motionTransfer, hasSource: true)
        let long = CreateFixture.video(duration: limits.duration.upperBound + 20)
        let tooLong = order {
            $0.source = AgentVideoOrder.Source(video: long, start: 0, end: limits.duration.upperBound + 5)
        }
        #expect(refusal(tooLong)?.contains("too long") == true)
        let tooShort = order(start: 0, end: max(0.5, limits.duration.lowerBound - 1))
        #expect(refusal(tooShort)?.contains("too short") == true)
        #expect(refusal(order(start: 0, end: 20))?.contains("past the clip") == true)
    }

    /// The form drops references over the limit; an agent's are refused.
    @Test func tooManyImagesAreRefusedNotDropped() {
        let most = VideoModel.genjutsu.limits(for: .motionTransfer, hasSource: true).referenceImages.upperBound
        #expect(refusal(order(images: most + 1))?.contains("at most \(most)") == true)
        #expect(refusal(order(images: 0))?.contains("at least") == true)
    }

    @Test func modelsThatCantDoItAreRefused() throws {
        #expect(refusal(order(model: "nope"))?.contains("no model nope") == true)
        let other = try #require(VideoModel.allCases.first { !$0.serves(.motionTransfer) })
        #expect(refusal(order(model: other.rawValue))?.contains("doesn't do motion_transfer") == true)
        #expect(refusal(order { $0.mode = "dance" })?.contains("mode is one of") == true)
    }

    @Test func aDraftOrResolutionTheModelLacksIsRefused() throws {
        if let noDraft = VideoModel.allCases.first(where: { !$0.offersDraft && $0.serves(.motionTransfer) }) {
            #expect(
                refusal(order(model: noDraft.rawValue, images: 1) { $0.isDraft = true })?.contains("no drafts") == true)
        }
        let missing = try #require(Resolution.allCases.first { !VideoModel.genjutsu.resolutions.contains($0) })
        #expect(refusal(order { $0.resolution = missing.rawValue })?.contains("renders at") == true)
        #expect(refusal(order { $0.resolution = "8K" })?.contains("renders at") == true)
    }

    @Test func aLengthOutsideTheWindowIsRefused() throws {
        let model = try #require(VideoModel.allCases.first { $0.makesClipsWithoutSource })
        let window = model.limits(for: .motionTransfer, hasSource: false).duration
        var noSource = order(model: model.rawValue)
        noSource.source = nil
        noSource.length = window.upperBound + 1
        #expect(refusal(noSource)?.contains("length is") == true)
        noSource.length = window.lowerBound
        #expect(refusal(noSource) == nil)
        // With a source the range sets the length.
        #expect(refusal(order { $0.length = 5 })?.contains("only for a clip without a source") == true)
    }

    @Test func otherFieldsAreCheckedByName() {
        #expect(refusal(order { $0.audio = "loud" })?.contains("audio is one of") == true)
        #expect(refusal(order { $0.aspectRatio = "16:9" })?.contains("without a source") == true)
        #expect(refusal(order { $0.aspectRatio = "2:1" })?.contains("aspect_ratio is one of") == true)
        // The connection's capabilities aren't known here, so it makes one video per job.
        #expect(refusal(order { $0.variants = 3 }) != nil)
        #expect(refusal(order(), in: CreateContext(connection: .none))?.contains("isn't connected") == true)
    }

    @Test func aQuoteStandsInForTheFiles() throws {
        let quote = AgentVideoOrder(
            mode: "motion_transfer", source: AgentVideoOrder.quoteSource(start: nil, end: 8),
            images: AgentVideoOrder.quoteImages(2))
        let spec = try quote.spec(from: base, in: context).get()
        #expect(spec.duration == 8)
        #expect(spec.references.count == 2)
        #expect(spec.source?.fileURL.path(percentEncoded: false).hasPrefix("/quote/") == true)
        // A result from a source keeps its orientation; one without says the frame it asks for.
        #expect(AgentVideoOrder.frame(of: spec) == "source")
        let prompted = JobSpec(
            mode: .motionTransfer, model: .seedance25, source: nil, prompt: "a fox", resolution: .p720,
            aspectRatio: .portrait)
        #expect(AgentVideoOrder.frame(of: prompted) == "9:16")
    }

    @Test func modeNamesRoundTrip() {
        for mode in Mode.allCases {
            #expect(AgentVideoOrder.modes[AgentVideoOrder.name(of: mode)] == mode)
        }
    }
}

@MainActor
@Suite struct AgentRequestLogTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("requests-\(UUID().uuidString)")

    func record(
        _ id: String, _ fingerprint: String = "f1", jobs: [UUID] = [UUID()], at date: Date = .now
    )
        -> AgentRequestLog.Record
    {
        AgentRequestLog.Record(requestID: id, fingerprint: fingerprint, jobIDs: jobs, createdAt: date)
    }

    @Test func aRequestIsNewKnownOrAConflictAndSurvivesARelaunch() throws {
        let job = UUID()
        let log = AgentRequestLog(folder: folder)
        #expect(try log.lookup("r1", fingerprint: "f1") == .new)
        try log.add(record("r1", jobs: [job]))

        let reopened = AgentRequestLog(folder: folder)
        #expect(try reopened.lookup("r1", fingerprint: "f1") == .known([job]))
        #expect(try reopened.lookup("r1", fingerprint: "f2") == .conflict)
        try reopened.remove("r1")
        #expect(try AgentRequestLog(folder: folder).lookup("r1", fingerprint: "f2") == .new)
    }

    /// An unreadable record refuses requests rather than forgetting which were made, which could pay twice.
    @Test func anUnreadableFileRefusesEveryRequest() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent("agent-requests.json"))
        let log = AgentRequestLog(folder: folder)
        #expect(throws: LogWriteError.self) { try log.lookup("r1", fingerprint: "f1") }
        #expect(throws: LogWriteError.self) { try log.add(record("r1")) }
    }

    @Test func oldRequestsAreForgotten() throws {
        let log = AgentRequestLog(folder: nil)
        try log.add(record("old", at: .now.addingTimeInterval(-40 * 86_400)))
        try log.add(record("new"))
        #expect(try log.lookup("old", fingerprint: "f1") == .new)
        #expect(try log.lookup("new", fingerprint: "f1") != .new)
    }
}

@Suite struct AgentJobTests {
    func agentJob(_ state: JobState, hold: AgentHold? = nil, cost: Cost = .usd(1.3, isEstimate: false)) -> Job {
        var job = Job(
            spec: JobSpec(mode: .motionTransfer, source: nil, resolution: .p720), providerKind: .apiKey, cost: cost)
        job.state = state
        job.agent = AgentOrigin(
            client: "claude-code", requestID: "r1", maxCost: AgentMoney(250, .usdCents), hold: hold)
        return job
    }

    @Test func theQueueRowSaysWhichAgentAndWhatItMaySpend() {
        let row = JobRowModel(agentJob(.preparing), now: .now)
        #expect(row.origin == "Agent · claude-code")
        #expect(row.originDetail == "Allowed up to \(CostText.dollars(2.5))")
        #expect(
            JobRowModel(
                Job(spec: agentJob(.preparing).spec, providerKind: .apiKey, cost: .usd(1, isEstimate: false)),
                now: .now
            ).origin == nil)
    }

    @Test func aHeldJobWaitsForThePersonsConfirmation() {
        let row = JobRowModel(agentJob(.paused(.agentLimit), hold: .overMaxCost), now: .now)
        #expect(row.note?.text.contains("allowed") == true)
        #expect(row.actions.first == .confirmPrice)
        for hold in [AgentHold.unknownPrice, .overDailyBudget, .ledgerUnavailable] {
            #expect(JobRowModel(agentJob(.paused(.agentLimit), hold: hold), now: .now).note != nil)
        }
    }

    @Test func agentsSeeStableNamesAndWhoMustAct() {
        let held = AgentJobStatus(agentJob(.paused(.agentLimit), hold: .overDailyBudget))
        #expect(held.state == "paused" && held.pauseReason == "agent_limit" && held.hold == "over_daily_budget")
        #expect(held.needsPerson)
        #expect(held.price == AgentMoney(130, .usdCents) && held.isPriceExact)
        let byUser = AgentJobStatus(agentJob(.paused(.byUser)))
        #expect(!byUser.needsPerson && byUser.hold == nil)
        #expect(AgentJobStatus(agentJob(.waitingForSlot, cost: .unknownUSD)).price == nil)
        #expect(AgentJobStatus(agentJob(.failed(reason: .outcomeUnknown))).error != nil)
        // From the string catalog, as the Queue says it.
        #expect(AgentJobStatus(agentJob(.rejected)).error == "Rejected by content moderation")
    }

    /// A raise that didn't lift the job changed nothing: the note says it stays held over its old max_cost and how the
    /// same request can lift it later, not that it now waits for the person.
    @Test func aRaiseStillHeldSaysTheJobStaysOverItsOldMaxCost() {
        for hold in [AgentHold.overDailyBudget, .ledgerUnavailable, nil] {
            let note = AgentJobRules.stillHeldNote(hold)
            #expect(note.contains("stays held over its old max_cost") && note.contains("Send the request again"))
        }
    }

    /// A finished video points the agent to frames, against its source when it has one.
    @Test func aFinishedVideoSaysHowToCheckItWithFrames() throws {
        var done = agentJob(.done)
        done.outputFile = URL(filePath: "/tmp/out.mp4")
        let plain = try #require(AgentJobRules.checkHint(done))
        #expect(plain.contains("frames with item \(done.id.uuidString)") && !plain.contains("compare_source"))
        done.spec.source = SourceClip(
            fileURL: URL(filePath: "/tmp/in.mov"), duration: 5, pixelSize: PixelSize(width: 576, height: 1024),
            range: 0...5)
        #expect(AgentJobRules.checkHint(done)?.contains("compare_source true") == true)
        #expect(AgentJobRules.checkHint(agentJob(.processing)) == nil)
        #expect(AgentJobRules.checkHint(agentJob(.done)) == nil)
    }

    /// over_cap says what the cap counted, in the whole units agents read, and that it isn't the agent budget.
    @Test func overCapGivesTheCapTodayAndTheJobsPrice() {
        let credits = AgentCap.overCapMessage(
            cap: .credits(300), committedToday: 290, price: .credits(24, isEstimate: false))
        #expect(credits.contains("daily cap of 300 credits") && credits.contains("290 credits are spent or queued"))
        #expect(credits.contains("counts at 24 credits") && credits.contains("apart from the agent budget"))
        let dollars = AgentCap.overCapMessage(cap: .usd(5), committedToday: 4.5, price: .usd(1.301, isEstimate: true))
        #expect(dollars.contains("500 usd_cents") && dollars.contains("450 usd_cents"))
        #expect(dollars.contains("counts at 131 usd_cents"))
        #expect(AgentCap.overCapMessage(cap: .usd(5), committedToday: 0, price: .unknownUSD).contains("unknown price"))
    }

    /// A create_video wait ends once the guard can read the price, the job is past the guard, or it is held.
    @Test func aCreateVideoWaitEndsOnceThePriceIsKnownOrTheJobIsHeld() {
        let estimate = Cost.credits(24, isEstimate: true)
        #expect(!AgentJobStatus.isPriced(agentJob(.preparing, cost: estimate)))
        #expect(!AgentJobStatus.isPriced(agentJob(.uploading, cost: .unknownUSD)))
        var quoted = agentJob(.waitingForSlot, cost: estimate)
        quoted.serverPrice = .credits(24, isEstimate: false)
        #expect(AgentJobStatus.isPriced(quoted))
        #expect(AgentJobStatus.isPriced(agentJob(.preparing)))
        #expect(AgentJobStatus.isPriced(agentJob(.paused(.agentLimit), hold: .unknownPrice, cost: estimate)))
        #expect(AgentJobStatus.isPriced(agentJob(.failed(reason: .generationFailed), cost: estimate)))
        var sending = agentJob(.waitingForSlot, cost: estimate)
        sending.submitAttempt = SubmitAttempt(isIdempotent: true)
        #expect(AgentJobStatus.isPriced(sending))
    }

    @Test func agentsActOnlyOnTheirOwnJobsAndNeverRetryWhatMayBeCharged() {
        let own = agentJob(.failed(reason: .generationFailed))
        #expect(AgentJobRules.retryRefusal(own) == nil)
        var maybeCharged = agentJob(.failed(reason: .outcomeUnknown))
        maybeCharged.submitAttempt = SubmitAttempt(isIdempotent: false)
        #expect(AgentJobRules.retryRefusal(maybeCharged) != nil)
        var persons = own
        persons.agent = nil
        #expect(AgentJobRules.retryRefusal(persons) != nil)
        #expect(AgentJobRules.cancelRefusal(persons) != nil)
        #expect(AgentJobRules.runNextRefusal(persons) != nil)
    }

    /// A wait ends once settled, or when its time is up; it never stops anything itself.
    @Test func aWaitEndsWhenSettledOrTimedOut() async {
        var sleeps = 0
        let settledAtOnce = await agentWait(seconds: 50, isSettled: { true }, sleep: { _ in sleeps += 1 })
        #expect(!settledAtOnce && sleeps == 0)

        var checks = 0
        let settledLater = await agentWait(
            seconds: 50,
            isSettled: {
                checks += 1
                return checks == 3
            }, sleep: { _ in sleeps += 1 })
        #expect(!settledLater && sleeps == 2)

        var clock = ContinuousClock.now
        sleeps = 0
        let timedOut = await agentWait(
            seconds: 2, milliseconds: 500, isSettled: { false }, now: { clock },
            sleep: {
                sleeps += 1
                clock += $0
            })
        #expect(timedOut && sleeps == 4)
    }

    @Test func aWaitEndsByTheClockWhenSleepsRunLong() async {
        var clock = ContinuousClock.now
        let start = clock
        var sleeps = 0
        // Each 500 ms sleep takes 3 s, as in the background: the wait still ends at 50 s, not after 100 sleeps.
        let timedOut = await agentWait(
            seconds: 50, isSettled: { false }, now: { clock },
            sleep: { _ in
                sleeps += 1
                clock += .seconds(3)
            })
        #expect(timedOut && sleeps == 17 && clock - start <= .seconds(51))
    }
}
