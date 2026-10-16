import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct UnlimitedPresentationTests {
    /// An account whose allowance covers Genjutsu Motion Transfer, with a 100-credit cap nearly spent.
    static func context(optedIn: Bool = true, credits: Int? = 10) -> CreateContext {
        CreateContext(
            connection: .account(AccountInfo(credits: credits)),
            capabilities: Capabilities(
                modes: [.motionTransfer, .objectSwap], resolutions: Set(Resolution.allCases), costUnit: .credits,
                maxConcurrency: nil, unlimited: [.genjutsu: [.motionTransfer]]),
            committedToday: 95, cap: .credits(100), unlimitedOptIn: optedIn)
    }

    @Test func theCostLineSaysUnlimitedAndTheCapAndCreditsDontHoldItBack() throws {
        let form = CreateFixture.ready()
        let context = Self.context()

        let line = try #require(form.costLine(in: context))
        #expect(line.text.hasSuffix("· Unlimited"))
        #expect(line.detail.contains("not counted in the daily cap"))
        #expect(!line.isWarning)
        #expect(form.priceText(isDraft: false, in: context) == "Unlimited")
        #expect(SubmitBarState(form: form, in: context).price(isDraft: true) == "Unlimited")
        #expect(form.blocker(isDraft: false, in: context) == nil)
        #expect(form.submitDecision(isDraft: false, in: context) == .start(form.makeSpecs(isDraft: false)))
    }

    @Test func withoutTheOptInOrForAnotherModeItsCredits() throws {
        var form = CreateFixture.ready()
        let spec = try #require(form.makeSpecs(isDraft: false).first)
        var context = Self.context(optedIn: false)
        context.estimates[spec.priceKey] = .credits(40, isEstimate: true)
        #expect(form.priceText(isDraft: false, in: context) == "40 cr")
        #expect(form.costLine(in: context)?.isWarning == true)

        form.mode = .objectSwap
        #expect(!Self.context().paysUnlimited(form.makeSpecs(isDraft: false)))
    }

    @Test func theSettingIsOfferedOnlyForWhatTheAllowanceCovers() {
        var capabilities = Self.context().capabilities
        #expect(capabilities?.unlimitedText == "Genjutsu Motion transfer")
        capabilities?.unlimited = [.seedance25: [.motionTransfer], .genjutsu: [.objectSwap, .motionTransfer]]
        #expect(capabilities?.unlimitedText == "Genjutsu Motion transfer · Genjutsu Object swap · Seedance 2.5")
        capabilities?.unlimited = [:]
        #expect(capabilities?.unlimitedText == nil)
    }

    @Test func theSettingIsOffByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "UnlimitedPresentationTests"))
        defaults.removePersistentDomain(forName: "UnlimitedPresentationTests")
        #expect(!AppSettings.usesUnlimited(in: defaults))
        defaults.set(true, forKey: AppSettings.useUnlimitedKey)
        #expect(AppSettings.usesUnlimited(in: defaults))
        defaults.removePersistentDomain(forName: "UnlimitedPresentationTests")
    }

    @Test func aQueuedUnlimitedJobReadsUnlimitedAndSpendsNothing() {
        var job = JobFixture.job(.done, kind: .account, cost: .credits(40, isEstimate: true), finishedMinutesAgo: 1)
        job.spec.usesUnlimited = true

        let row = JobRowModel(job, now: JobFixture.now)
        #expect(row.cost == "Unlimited")
        #expect(row.priceSource == "Unlimited generations of the plan")
        let summary = SpendingSummary([job], period: .today, now: JobFixture.now)
        #expect(summary.charged == SpendTotal())
        #expect(summary.chargedJobs == 1)
    }

    @Test func turningOutToCostCreditsChangesTheCommittedSpendKey() {
        var job = JobFixture.job(.processing, kind: .account, cost: .credits(40, isEstimate: true))
        job.spec.usesUnlimited = true
        let before = CommittedSpendKey([job], unit: .credits)
        job.spec.usesUnlimited = false
        #expect(CommittedSpendKey([job], unit: .credits) != before)
    }
}
