import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// A scoring provider whose answers the test scripts, one per call in order, the last one repeated.
private actor FakeScorer: ViralityScoring {
    var answers: [Result<ViralityOutcome, any Error>]
    private(set) var scored: [String] = []

    init(_ answers: [Result<ViralityOutcome, any Error>]) {
        self.answers = answers
    }

    func viralityEstimate(jobID: String) async throws -> Cost? { nil }

    func scoreVirality(jobID: String) async throws -> ViralityOutcome {
        scored.append(jobID)
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        return try answer.get()
    }
}

/// Score Variants in batch comparison (issue #45): who can be scored, what is charged, and what is kept.
@MainActor
@Suite struct VariantScoringTests {
    static let owner = "user_1"
    nonisolated static let scoredAt = Date(timeIntervalSince1970: 2_000_000)
    static let disclaimer = "Predictive proxy metrics, not guaranteed performance or clinical measures."
    /// The readings of a live run on 2026-10-15 (issue #111).
    static let score = ViralityScore(
        score: 46, viralPotential: 45, hook: 29, engagement: 39, sustain: 100, peakSecond: 12,
        perFrame: [0.2, 0.42, 0.3], disclaimer: disclaimer,
        reportURL: URL(string: "https://cdn.example/virality/job.html"), scoredAt: scoredAt)

    /// A finished account result of `owner` with the job ID `requestID`.
    static func item(
        _ requestID: String? = "job-1", kind: ProviderKind = .account, owner: String? = owner,
        state: JobState = .done, virality: ViralityScore? = nil
    ) -> LibraryItemModel {
        var job = JobFixture.job(state, kind: kind)
        job.owner = owner
        job.remote = requestID.map { RemoteJob(requestID: $0) }
        job.outputFile = URL(fileURLWithPath: "/out/\(requestID ?? "none").mp4")
        job.virality = virality
        return LibraryItemModel(job: job)
    }

    /// An API key's provider doesn't score virality, so it passes no scorer, as a missing connection does.
    @Test func shownOnlyWhereTheConnectionScoresAndOffWhileUnconfirmed() {
        let scorer = FakeScorer([.success(ViralityOutcome(score: nil, charged: nil))])
        #expect(ViralityAvailability.of(scorer: nil, offered: true) == .hidden)
        #expect(
            ViralityAvailability.of(scorer: scorer, offered: false)
                == .disabled(reason: "Waiting for the account's tool catalog to be confirmed"))
        #expect(ViralityAvailability.of(scorer: scorer, offered: true) == .available)
    }

    @Test func onlyFinishedResultsOfThisAccountWithAJobIDCanBeScored() {
        #expect(Self.item().viralityJobID(owner: Self.owner) == "job-1")
        #expect(Self.item(kind: .apiKey).viralityBlocker(owner: Self.owner) == "Can't be scored: made with an API key")
        #expect(
            Self.item(owner: "user_2").viralityBlocker(owner: Self.owner) == "Can't be scored: made by another account")
        #expect(Self.item(nil).viralityBlocker(owner: Self.owner) == "Can't be scored: no account job ID")
        #expect(
            Self.item(state: .failed(reason: .message("x"))).viralityBlocker(owner: Self.owner)
                == "Can't be scored: not finished"
        )
        #expect(Self.item(kind: .apiKey).viralityJobID(owner: Self.owner) == nil)
    }

    @Test func thePlanSkipsScoredResultsAndRescoresOnlyWhenAllAre() {
        let scored = Self.item("job-1", virality: Self.score)
        let fresh = Self.item("job-2")
        let apiKey = Self.item("job-3", kind: .apiKey)

        let plan = ViralityPlan([scored, fresh, apiKey], owner: Self.owner)
        #expect(plan.entries.map(\.jobID) == ["job-2"])
        #expect(!plan.isRescore)
        #expect(plan.buttonTitle == "Score Variants…")

        let again = ViralityPlan([scored, apiKey], owner: Self.owner)
        #expect(again.entries.map(\.jobID) == ["job-1"])
        #expect(again.isRescore)
        #expect(again.buttonTitle == "Score Again…")

        let none = ViralityPlan([apiKey], owner: Self.owner)
        #expect(none.blocker == "None of these results can be scored")
        #expect(!none.isRescore)
    }

    @Test func thePriceIsForEveryVideoOrUnknown() {
        let plan = ViralityPlan([Self.item("job-1"), Self.item("job-2"), Self.item("job-3")], owner: Self.owner)

        let quoted = plan.total(each: .credits(4, isEstimate: false))
        #expect(quoted == .credits(12, isEstimate: false))
        #expect(plan.priceText(quoted) == "3 videos · 12 cr · Price from Higgsfield")
        #expect(plan.total(each: nil) == .unknownCredits)
        #expect(plan.total(each: .unknownCredits) == .unknownCredits)
        #expect(
            plan.priceText(.unknownCredits)
                == "3 videos · Price unknown — charged on completion. Higgsfield gives no quote for this before it runs."
        )
        let one = ViralityPlan([Self.item()], owner: Self.owner)
        #expect(one.priceText(.credits(4, isEstimate: true)) == "1 video · About 4 cr · Estimate")
    }

    /// The account's Virality Predictor costs nothing (live run, 2026-10-15).
    @Test func aFreeRunSaysFreeAndNeverAsksAboutTheCap() {
        let plan = ViralityPlan([Self.item("job-1"), Self.item("job-2")], owner: Self.owner)
        let free = plan.total(each: .credits(0, isEstimate: false))

        #expect(ViralityPlan.isFree(free))
        #expect(!ViralityPlan.isFree(.unknownCredits))
        #expect(plan.priceText(free) == "2 videos · Free")
        #expect(ViralityPlan.priceTag(free) == "Free")
        #expect(ViralityPlan.priceTag(.credits(4, isEstimate: false)) == "4 cr")
        #expect(ViralityPlan.capConfirmation(total: free, committedToday: 150, cap: .credits(100)) == nil)
    }

    @Test func underACapAnUnknownOrTooHighPriceAsks() {
        let cap = SpendCap.credits(100)
        #expect(ViralityPlan.capConfirmation(total: .unknownCredits, committedToday: 10, cap: nil) == nil)
        #expect(
            ViralityPlan.capConfirmation(total: .unknownCredits, committedToday: 10, cap: cap)?.title
                == "Price not known yet")
        #expect(
            ViralityPlan.capConfirmation(total: .credits(12, isEstimate: false), committedToday: 10, cap: cap) == nil)
        let over = ViralityPlan.capConfirmation(total: .credits(12, isEstimate: false), committedToday: 95, cap: cap)
        #expect(over?.title == "Over today's spend cap")
        #expect(over?.confirmTitle == "Score anyway")
    }

    @Test func theBadgeAndItsHoverNameTheReadings() {
        #expect(Self.score.badgeText == "46")
        #expect(
            Self.score.details == [
                "Viral potential: 45", "Hook (0–3 s): 29", "Engagement: 39", "Sustain: 100", "Peak at 12 s",
            ])
        #expect(
            Self.score.help
                == """
                Virality score 46 of 100
                Viral potential: 45
                Hook (0–3 s): 29
                Engagement: 39
                Sustain: 100
                Peak at 12 s
                \(Self.disclaimer)
                """)
        #expect(Self.score.accessibilityLabel.hasPrefix("Virality score 46 of 100, Viral potential: 45, "))
        let report = ViralityScore(reportURL: URL(string: "https://cdn.example/r.html"), scoredAt: Self.scoredAt)
        #expect(report.badgeText == nil)
        #expect(report.help == "Virality report on Higgsfield")
    }

    @Test func theLineSpansTheReadingsLowestToHighest() {
        #expect(Self.score.curve.map { ($0 * 100).rounded() } == [0, 100, 45])
        #expect(ViralityScore(perFrame: [0.3], scoredAt: Self.scoredAt).curve.isEmpty)
        #expect(ViralityScore(perFrame: [0.3, 0.3], scoredAt: Self.scoredAt).curve.isEmpty)
        #expect(ViralityScore(scoredAt: Self.scoredAt).curve.isEmpty)
    }

    @Test func eachScoreIsSavedAndItsPriceCounted() async {
        let spend = ImageSpendLog(folder: nil)
        let scorer = VariantScorer(spend: spend, now: { Self.scoredAt })
        let provider = FakeScorer([.success(ViralityOutcome(score: Self.score, charged: nil))])
        let plan = ViralityPlan([Self.item("job-1"), Self.item("job-2")], owner: Self.owner)
        var saved: [UUID] = []

        await scorer.score(plan, provider: provider, each: .credits(4, isEstimate: false)) { id, _ in
            saved.append(id)
        }
        await eventually { !scorer.isRunning }

        #expect(await provider.scored == ["job-1", "job-2"])
        #expect(saved == plan.entries.map(\.itemID))
        #expect(spend.charges.map(\.purpose) == [.viralityScore, .viralityScore])
        #expect(spend.charges.allSatisfy { !$0.isPending && $0.cost == .credits(4, isEstimate: false) })
        #expect(DailySpend.committed([], images: spend.charges, on: Self.scoredAt, in: .credits) == 8)
        #expect(!scorer.isRunning)
        #expect(scorer.failures.isEmpty)
    }

    @Test func anUnreadableAnswerKeepsNoScoreButCountsTheCharge() async {
        let spend = ImageSpendLog(folder: nil)
        let scorer = VariantScorer(spend: spend, now: { Self.scoredAt })
        let provider = FakeScorer([.success(ViralityOutcome(score: nil, charged: .credits(3, isEstimate: false)))])
        let plan = ViralityPlan([Self.item()], owner: Self.owner)
        var saved = 0

        await scorer.score(plan, provider: provider, each: .unknownCredits) { _, _ in saved += 1 }
        await eventually { !scorer.isRunning }

        #expect(saved == 0)
        #expect(spend.charges.map(\.cost) == [.credits(3, isEstimate: false)])
        #expect(spend.charges.first?.isPending == false)
        #expect(scorer.failures[plan.entries[0].itemID] == VariantScorer.unreadable)
    }

    @Test func aRefusalIsNotChargedButALostAnswerIs() async {
        let spend = ImageSpendLog(folder: nil)
        let scorer = VariantScorer(spend: spend, now: { Self.scoredAt })
        let provider = FakeScorer([
            .failure(ProviderError.validation(field: nil, message: "Too long")),
            .failure(ProviderError.outcomeUnknown),
        ])
        let plan = ViralityPlan([Self.item("job-1"), Self.item("job-2")], owner: Self.owner)

        await scorer.score(plan, provider: provider, each: .credits(4, isEstimate: false)) { _, _ in }
        await eventually { !scorer.isRunning }

        #expect(spend.charges.count == 1)
        #expect(spend.charges.first?.isPending == false)
        #expect(scorer.failures.count == 2)
        #expect(scorer.failures[plan.entries[0].itemID] == "Too long")
    }

    /// Score reads today's spend itself right before the run, so a screen can't skip the cap.
    @Test func scoringAsksBeforeGoingPastTheCapAndRunsOnceAgreed() async {
        let spend = ImageSpendLog(folder: nil)
        var committed = Decimal(0)
        let scorer = VariantScorer(
            spend: spend,
            spendStatus: { kind in
                kind == .account ? SpendStatus(committedToday: committed, cap: .credits(100)) : nil
            },
            now: { Self.scoredAt })
        let provider = FakeScorer([.success(ViralityOutcome(score: Self.score, charged: nil))])
        let plan = ViralityPlan([Self.item("job-1"), Self.item("job-2")], owner: Self.owner)
        func score(each: Cost, approved: Bool = false) async -> PaidStart {
            await scorer.score(plan, provider: provider, each: each, overCapApproved: approved, save: { _, _ in })
        }

        // Under the cap: runs.
        #expect(await score(each: .credits(4, isEstimate: false)) == .started)
        await eventually { !scorer.isRunning }

        // A price not known, under a cap: asks, scores nothing.
        guard case .needsConfirmation(let unknown) = await score(each: .unknownCredits) else {
            Issue.record("Expected a question about the unknown price")
            return
        }
        #expect(unknown.title == "Price not known yet")

        // 95 + 2 × 4 credits goes past 100: asks, scores nothing.
        committed = 95
        guard case .needsConfirmation(let over) = await score(each: .credits(4, isEstimate: false)) else {
            Issue.record("Expected a question about the cap")
            return
        }
        #expect(over.confirmTitle == "Score anyway")
        #expect(!scorer.isRunning)
        #expect(await provider.scored.count == 2)
        #expect(spend.charges.count == 2)

        // Agreed: runs without asking again.
        #expect(await score(each: .credits(4, isEstimate: false), approved: true) == .started)
        await eventually { !scorer.isRunning }
        #expect(await provider.scored.count == 4)
        #expect(spend.charges.count == 4)
    }

    @Test func spendingHasALineAndRowsForScores() {
        let calendar = Calendar(identifier: .gregorian)
        let charge = ImageCharge(
            date: Self.scoredAt, cost: .credits(4, isEstimate: false), providerKind: .account,
            model: VariantScorer.modelTitle, images: 1, isPending: false, purpose: .viralityScore)
        let image = ImageCharge(
            date: Self.scoredAt, cost: .credits(2, isEstimate: false), providerKind: .account, model: "Soul",
            images: 1, isPending: false)

        let summary = SpendingSummary(
            [], images: [charge, image], period: .today, now: Self.scoredAt, calendar: calendar)
        let csv = SpendingCSV.csv([], images: [charge], timeZone: TimeZone(secondsFromGMT: 0)!)

        #expect(summary.byMode.map(\.title) == ["Reference images", "Virality scores"])
        #expect(summary.charged.credits == 6)
        #expect(
            csv.components(separatedBy: "\r\n").dropFirst().first
                == "1970-01-24T03:33:20Z,Virality scores,,No,0,4,credits,Done,Yes,")
    }

    @Test func aScoreStoredWithTheGuessedReadingsStillDecodes() throws {
        let old = Data(
            """
            {"score":72,"hookStrength":{"value":81},"retentionRisk":{"label":"medium"},"scoredAt":0}
            """.utf8)
        let score = try JSONDecoder().decode(ViralityScore.self, from: old)
        #expect(score.score == 72)
        #expect(score.hook == nil)
        #expect(score.perFrame == nil)
    }

    @Test func chargesAndJobsStoredBeforeScoresStillDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = Data(
            """
            [{"id":"6F2B0E5E-3C1B-4F43-9C8A-1D2E3F4A5B6C","date":"2026-10-14T10:00:00Z",
            "cost":{"credits":{"_0":2,"isEstimate":false}},"providerKind":"account","model":"Soul","images":1,
            "isPending":false}]
            """.utf8)
        let charges = try decoder.decode([ImageCharge].self, from: old)
        #expect(charges.first?.purpose == nil)
        #expect(charges.first?.paidFor == .referenceImages)

        var job = JobFixture.job(.done)
        job.virality = Self.score
        let data = try JSONEncoder().encode(job)
        #expect(try JSONDecoder().decode(Job.self, from: data).virality == Self.score)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["virality"] = nil
        let stripped = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Job.self, from: stripped).virality == nil)
    }
}
