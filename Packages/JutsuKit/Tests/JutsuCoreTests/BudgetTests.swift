import Foundation
import Testing

@testable import JutsuCore

@Test func withinCapIsAllowed() {
    #expect(Budget.allows(cost: .usd(5, isEstimate: false), committedToday: 70, cap: .usd(75)) == .allowed)
}

@Test func overCapNeedsConfirmationWithTheNewTotal() throws {
    let cost = Cost.usd(try #require(Decimal(string: "5.01")), isEstimate: false)
    let total = try #require(Decimal(string: "75.01"))
    #expect(Budget.allows(cost: cost, committedToday: 70, cap: .usd(75)) == .needsConfirmation(total: total))
}

@Test func noCapAllowsAnything() {
    #expect(Budget.allows(cost: .usd(1_000, isEstimate: false), committedToday: 1_000, cap: nil) == .allowed)
}

@Test func creditCapLimitsCredits() {
    #expect(Budget.allows(cost: .credits(100, isEstimate: true), committedToday: 400, cap: .credits(500)) == .allowed)
    #expect(
        Budget.allows(cost: .credits(101, isEstimate: true), committedToday: 400, cap: .credits(500))
            == .needsConfirmation(total: 501))
}

@Test func aCapNeverLimitsTheOtherUnit() {
    #expect(Budget.allows(cost: .credits(1_000, isEstimate: true), committedToday: 1_000, cap: .usd(1)) == .allowed)
    #expect(Budget.allows(cost: .usd(1_000, isEstimate: false), committedToday: 1_000, cap: .credits(1)) == .allowed)
}

@Test func refinedPriceOverTheCapNeedsTheUserOnlyWhenThePreliminaryFit() {
    func check(committed: Decimal, approved: Cost? = nil, cap: SpendCap? = .usd(75)) -> Bool {
        Budget.refinedPriceNeedsConfirmation(
            preliminary: .usd(4, isEstimate: false), refined: .usd(6, isEstimate: false), approved: approved,
            committedToday: committed, cap: cap)
    }

    #expect(check(committed: 70))
    #expect(!check(committed: 60))
    #expect(!check(committed: 72), "the user already confirmed the preliminary price")
    #expect(!check(committed: 70, cap: nil))
    #expect(!check(committed: 70, approved: .usd(6, isEstimate: false)))
    #expect(check(committed: 70, approved: .usd(5, isEstimate: false)))
    #expect(check(committed: 70, approved: .credits(100, isEstimate: false)))
    #expect(check(committed: 72, approved: .usd(4, isEstimate: false)), "agreed to 4 over the cap, not 6")
}

@Test func jobsPaidFromTheUnlimitedAllowanceDontCount() {
    var credits = Job(spec: makeSpec(), providerKind: .account, cost: .credits(40, isEstimate: true))
    credits.state = .processing
    var unlimited = credits
    unlimited.spec.usesUnlimited = true
    #expect(Budget.committed([credits, unlimited], on: .now, in: .credits) == 40)
}

@Test func onlyAnOptedInSpecTheAllowanceCoversPaysUnlimited() {
    let capabilities = Capabilities(
        modes: [.motionTransfer, .objectSwap], resolutions: [.p480], costUnit: .credits, maxConcurrency: nil,
        unlimited: [.genjutsu: [.motionTransfer]])
    #expect(capabilities.paysUnlimited(makeSpec(), optedIn: true))
    #expect(!capabilities.paysUnlimited(makeSpec(), optedIn: false))
    #expect(!capabilities.paysUnlimited(makeSpec(mode: .objectSwap), optedIn: true))
}

@Test func failedJobsThatMayHaveBeenChargedCountOnTheDayTheyEnded() {
    let day = Date(timeIntervalSince1970: 1_791_892_800)
    func failed(_ change: (inout Job) -> Void) -> Job {
        var job = Job(spec: makeSpec(), providerKind: .account, cost: .credits(10, isEstimate: true))
        job.state = .failed(reason: .message("x"))
        job.finishedAt = day
        change(&job)
        return job
    }
    let unknown = failed { $0.submitAttempt = SubmitAttempt(isIdempotent: false) }
    let pastDeadline = failed {
        $0.state = .failed(reason: .deadline)
        $0.timedOutAt = day
        $0.remote = RemoteJob(requestID: "r1")
    }
    let refused = failed { _ in }
    let chargedTheDayBefore = failed {
        $0.chargedAt = day.addingTimeInterval(-24 * 3600)
        $0.remote = RemoteJob(requestID: "r2")
    }

    #expect(Budget.committed([unknown, pastDeadline, refused, chargedTheDayBefore], on: day, in: .credits) == 20)
}

@Test func anUnknownPriceUnderACapNeedsTheUser() {
    #expect(Budget.allows(cost: .unknownCredits, committedToday: 0, cap: .credits(100)) == .needsConfirmation(total: 0))
    #expect(Budget.allows(cost: .unknownCredits, committedToday: 0, cap: nil) == .allowed)
    #expect(Budget.allows(cost: .unknownUSD, committedToday: 0, cap: .credits(100)) == .allowed)
}
