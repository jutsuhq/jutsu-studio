import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct CreateFormRangesTests {
    /// 3 × 10 s out of a 47.3 s clip, the third range being edited.
    static func threeRanges(_ resolution: Resolution = .p720) -> CreateForm {
        var form = CreateFixture.ready(resolution)
        form.setSource(CreateFixture.video(duration: 47.3))
        form.setEnd(10)
        form.addRange()
        form.addRange()
        return form
    }

    @Test func singleRangeKeepsTheOneRangeTexts() {
        CostText.$locale.withValue(.enUS) {
            var form = CreateFixture.ready()
            form.setSource(CreateFixture.video(duration: 47.3))
            form.setStart(6)
            form.setEnd(18.5)
            #expect(!form.hasSeveralRanges)
            #expect(form.ranges == [6...18.5])
            #expect(form.sourceSummary == "00:06.0 – 00:18.5 · 12.5 s")
            #expect(form.trimSummary(on: .apiKey) == "12.5 s selected · billed 13 s")
            #expect(form.costLine(in: CreateFixture.apiKey)?.detail == "List price · failed runs are free")
        }
    }

    @Test func addedRangesFollowTheEditedOneAndTakeItsLength() {
        CostText.$locale.withValue(.enUS) {
            let form = Self.threeRanges()
            #expect(form.ranges == [0...10, 10...20, 20...30])
            #expect(form.selectedRangeIndex == 2)
            #expect(form.rangeText == "00:20.0 – 00:30.0")
            #expect(form.rangeText(at: 0) == "00:00.0 – 00:10.0")
            #expect(form.rangeText(at: 7).isEmpty)
            #expect(form.uncoveredRanges == [30...47.3])
            #expect(form.billedSeconds(on: .apiKey) == 30)
            #expect(form.trimSummary(on: .apiKey) == "10.0 s selected · 3 ranges · billed 30 s")
            #expect(form.sourceSummary == "3 ranges · 30.0 s")
        }
    }

    @Test func newRangeFitsTheFirstGapOfAtLeast4Seconds() {
        var form = CreateForm()
        form.setSource(CreateFixture.video(duration: 14.2))
        #expect(!form.canAddRange)
        form.addRange()
        #expect(form.ranges == [0...14.2])
        form.setEnd(10)
        #expect(form.canAddRange)
        form.addRange()
        #expect(form.ranges == [0...10, 10...14.2])
        #expect(!form.canAddRange)
        #expect(CreateForm().canAddRange == false)
    }

    @Test func rangeGoesBackIntoTheGapItLeft() {
        var form = Self.threeRanges()
        form.removeRange(at: 1)
        #expect(form.ranges == [0...10, 20...30])
        #expect(form.selectedRangeIndex == 1)
        form.selectRange(at: 0)
        form.addRange()
        #expect(form.ranges == [0...10, 10...20, 20...30])
        #expect(form.selectedRangeIndex == 1)
    }

    @Test func handlesStopAtTheNeighbors() {
        var form = Self.threeRanges()
        form.selectRange(at: 1)
        form.setEnd(25)
        #expect(form.range == 10...20)
        form.setStart(5)
        #expect(form.range == 10...20)
        form.moveRange(toStart: 0)
        #expect(form.range == 10...20)
        form.selectRange(at: 2)
        form.moveRange(toStart: 40)
        #expect(form.range == 37.3...47.3)
        form.selectRange(at: 1)
        form.setEnd(28)
        #expect(form.ranges == [0...10, 10...28, 37.3...47.3])
        form.moveRange(toStart: 30)
        #expect(form.range.upperBound == 37.3)
        #expect(abs(form.range.lowerBound - 19.3) < 1e-9)
    }

    @Test func removingKeepsAtLeastOneRangeAndAValidSelection() {
        var form = Self.threeRanges()
        form.removeRange(at: 2)
        #expect(form.selectedRangeIndex == 1)
        form.removeRange(at: 0)
        #expect(form.ranges == [10...20])
        #expect(form.selectedRangeIndex == 0)
        form.removeRange(at: 0)
        form.removeRange(at: 5)
        #expect(form.ranges == [10...20])
        #expect(!form.hasSeveralRanges)
    }

    @Test func newSourceOrLoadedJobHasOneRange() throws {
        var form = Self.threeRanges()
        let spec = try #require(form.makeSpecs(isDraft: false).last)
        form.load(spec, source: CreateFixture.video(duration: 47.3))
        #expect(form.ranges == [20...30])
        #expect(form.selectedRangeIndex == 0)
        form = Self.threeRanges()
        form.setSource(CreateFixture.video(duration: 14.2))
        #expect(form.ranges == [0...14.2])
        #expect(form.selectedRangeIndex == 0)
    }

    @Test func eachRangeIsOneJobWithTheSameInputs() {
        var form = Self.threeRanges(.p1080)
        form.prompt = "Rain"
        form.audio = .fadeOut
        let specs = form.makeSpecs(isDraft: false)
        #expect(specs.map(\.source?.range) == [0...10, 10...20, 20...30])
        #expect(Set(specs.map(\.prompt)) == ["Rain"])
        #expect(Set(specs.map(\.resolution)) == [.p1080])
        #expect(Set(specs.map(\.audio)) == [.fadeOut])
        #expect(Set(specs.map(\.references)).count == 1)
        #expect(specs.allSatisfy { !$0.isDraft })
    }

    @Test func draftLengthAppliesToEveryRange() {
        CostText.$locale.withValue(.enUS) {
            var form = Self.threeRanges()
            form.draftLength = .firstFiveSeconds
            let drafts = form.makeSpecs(isDraft: true)
            #expect(drafts.map(\.source?.range) == [0...5, 10...15, 20...25])
            #expect(drafts.allSatisfy { $0.isDraft && $0.resolution == .p480 })
            #expect(form.draftDuration == 15)
            #expect(form.draftLengthDetail(in: CreateFixture.apiKey) == "15.0 s · $4.77")
        }
    }

    @Test func draftLengthShowsWhenAnyRangeIsLongerThanTheShortDraft() {
        var form = CreateFixture.ready()
        form.setSource(CreateFixture.video(duration: 20))
        form.setEnd(4.5)
        form.addRange()
        #expect(form.ranges == [0...4.5, 4.5...9])
        #expect(!form.showsDraftLength)
        form.setEnd(12)
        #expect(form.showsDraftLength)
    }

    @Test func eachJobIsBilledInWholeSeconds() {
        CostText.$locale.withValue(.enUS) {
            var form = CreateFixture.ready()
            form.setSource(CreateFixture.video(duration: 20))
            form.setEnd(4.5)
            form.addRange()
            #expect(form.billedSeconds(on: .apiKey) == 10)
            #expect(form.costLine(in: CreateFixture.apiKey)?.text == "10 s × $0.681 = $6.81")
        }
    }

    @Test func costLineAndButtonsShowTheTotal() {
        CostText.$locale.withValue(.enUS) {
            let form = Self.threeRanges()
            let line = form.costLine(in: CreateFixture.apiKey)
            #expect(line?.text == "30 s × $0.681 = $20.43")
            #expect(line?.detail == "List price · 3 jobs · failed runs are free")
            #expect(form.priceText(isDraft: false, in: CreateFixture.apiKey) == "$20.43")
            #expect(form.priceText(isDraft: true, in: CreateFixture.apiKey) == "$9.54")
        }
    }

    @Test func creditsTotalNeedsEveryEstimate() {
        let form = Self.threeRanges()
        let specs = form.makeSpecs(isDraft: false)
        var context = CreateContext(connection: .account(AccountInfo(credits: 100)))
        context.estimates[specs[0]] = .credits(40, isEstimate: true)
        context.estimates[specs[1]] = .credits(40, isEstimate: true)
        #expect(form.priceText(isDraft: false, in: context) == nil)
        #expect(form.blocker(isDraft: false, in: context) == nil)
        context.estimates[specs[2]] = .credits(40, isEstimate: true)
        #expect(form.costLine(in: context)?.text == "30 s = 120 credits")
        #expect(form.blocker(isDraft: false, in: context) == "Not enough credits for Generate, try a draft")
    }

    @Test func mixedUnitsHaveNoTotal() {
        let specs = Self.threeRanges().makeSpecs(isDraft: false)
        let context = CreateContext(
            connection: .apiKey(keyID: "kid"), pricing: CreateFixture.pricing,
            estimates: [specs[0]: .credits(40, isEstimate: true)])
        #expect(context.cost(for: specs) == nil)
        #expect(context.cost(for: []) == nil)
        #expect(context.cost(for: Array(specs.dropFirst())) == .usd(Decimal(string: "13.62") ?? 0, isEstimate: false))
    }

    @Test func spendCapChecksTheSumAndAsksOnce() {
        CostText.$locale.withValue(.enUS) {
            var context = CreateFixture.apiKey
            context.committedToday = 60
            context.cap = .usd(75)
            var single = Self.threeRanges()
            single.removeRange(at: 0)
            single.removeRange(at: 0)
            #expect(single.submitDecision(isDraft: false, in: context) == .start(single.makeSpecs(isDraft: false)))

            let form = Self.threeRanges()
            #expect(form.costLine(in: context)?.isWarning == true)
            guard case .confirm(let specs, let confirmation) = form.submitDecision(isDraft: false, in: context) else {
                Issue.record("expected one confirmation for all ranges")
                return
            }
            #expect(specs == form.makeSpecs(isDraft: false))
            #expect(specs.count == 3)
            #expect(
                confirmation.message == "These 3 jobs add $20.43, bringing today to $80.43 against your $75.00 cap.")
        }
    }
}
