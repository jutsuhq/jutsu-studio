import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct CreateFormKeyboardTests {
    /// 0–30 s of a 47.3 s clip.
    static func longClip() -> CreateForm {
        var form = CreateFixture.ready()
        form.setSource(CreateFixture.video(duration: 47.3))
        return form
    }

    @Test func handlesMoveByATenthOfASecond() {
        var form = Self.longClip()
        form.nudge(.start, by: 1)
        #expect(form.range == 0.1...30)
        form.nudge(.end, by: -2)
        #expect(form.range == 0.1...29.8)
        #expect(form.time(of: .start) == 0.1)
        #expect(form.time(of: .end) == 29.8)
    }

    @Test func selectionMovesWhole() {
        var form = Self.longClip()
        form.setEnd(10)
        form.nudge(.selection, by: 3)
        #expect(form.range.lowerBound == 0.3)
        #expect(abs(form.range.upperBound - 10.3) < 1e-9)
        #expect(form.time(of: .selection) == 0.3)
        form.nudge(.selection, by: -5)
        #expect(form.range.lowerBound == 0)
        #expect(abs(form.selectedDuration - 10) < 1e-9)
    }

    @Test func nudgesAreClampedLikeADrag() {
        var form = Self.longClip()
        form.nudge(.start, by: -1)
        #expect(form.range == 0...30)
        // The 30 s window: the end can't move out while the start stays.
        form.nudge(.end, by: 1)
        #expect(form.range == 0...30)
        // Past the clip's end.
        form.moveRange(toStart: 40)
        form.nudge(.end, by: 1)
        #expect(form.range.upperBound == 47.3)
        form.nudge(.selection, by: 1)
        #expect(form.range.upperBound == 47.3)
    }

    @Test func stepsLandOnTheGrid() {
        var form = Self.longClip()
        form.setEnd(10)
        for _ in 0..<7 { form.nudge(.end, by: 1) }
        for _ in 0..<7 { form.nudge(.end, by: -1) }
        #expect(form.range == 0...10)
        #expect(form.billedSeconds(on: .apiKey) == 10)
        // An edge left between steps by a drag snaps to the grid in the direction of the step.
        form.setEnd(20)
        form.setStart(6.04)
        form.nudge(.start, by: 1)
        #expect(form.range.lowerBound == 6.1)
        form.setStart(6.06)
        form.nudge(.start, by: -1)
        #expect(form.range.lowerBound == 6)
    }

    @Test func nothingMovesWithoutASource() {
        var form = CreateForm()
        form.nudge(.end, by: 5)
        #expect(form.range == 0...0)
    }

    @Test func accessibilityValuesReadTheTimes() {
        CostText.$locale.withValue(.enUS) {
            var form = Self.longClip()
            form.setStart(6)
            form.setEnd(18.5)
            #expect(form.accessibilityValue(of: .start) == "00:06.0")
            #expect(form.accessibilityValue(of: .end) == "00:18.5")
            #expect(form.accessibilityValue(of: .selection) == "00:06.0 – 00:18.5")
            #expect(TrimPart.allCases.map(\.accessibilityLabel) == ["Trim start", "Trim end", "Trim range"])
        }
    }

    @Test func primarySubmitIsGenerateOutsideABatch() {
        let form = CreateFixture.ready()
        let submit = form.primarySubmit(in: CreateFixture.apiKey)
        #expect(submit == PrimarySubmit(title: "Generate", isDraft: false, isEnabled: true))
        #expect(!form.primarySubmit(in: CreateFixture.apiKey, isSubmitting: true).isEnabled)
    }

    @Test func primarySubmitIsDisabledWhileBlocked() {
        var form = CreateFixture.ready()
        form.setSource(nil)
        #expect(!form.primarySubmit(in: CreateFixture.apiKey).isEnabled)
        let disconnected = CreateContext(connection: ConnectionState.none, pricing: CreateFixture.pricing)
        #expect(!CreateFixture.ready().primarySubmit(in: disconnected).isEnabled)
    }

    @Test func primarySubmitIsTheDraftInABatch() {
        var form = CreateFixture.ready()
        form.isBatch = true
        let submit = form.primarySubmit(in: CreateFixture.apiKey)
        #expect(submit.isDraft)
        #expect(submit.title == form.draftButtonTitle)
    }
}

@Suite struct CommittedSpendKeyTests {
    static func job(_ state: JobState = .processing) -> Job {
        let source = SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 30,
            pixelSize: PixelSize(width: 1280, height: 720), range: 0...10)
        var job = Job(
            spec: JobSpec(mode: .motionTransfer, source: source, resolution: .p720, isDraft: false),
            providerKind: .apiKey, cost: .usd(7, isEstimate: true))
        job.state = state
        return job
    }

    @Test func progressDoesNotChangeTheKey() {
        var job = Self.job()
        let before = CommittedSpendKey([job], unit: .usd)
        job.progress = 0.5
        #expect(CommittedSpendKey([job], unit: .usd) == before)
    }

    @Test func stateAndPriceAndUnitDo() {
        var job = Self.job()
        let before = CommittedSpendKey([job], unit: .usd)
        #expect(CommittedSpendKey([job], unit: .credits) != before)
        #expect(CommittedSpendKey([], unit: .usd) != before)
        job.serverPrice = .usd(9, isEstimate: false)
        #expect(CommittedSpendKey([job], unit: .usd) != before)
        job.serverPrice = nil
        job.state = .failed(reason: .message("x"))
        #expect(CommittedSpendKey([job], unit: .usd) != before)
    }

    @Test func nextDayIsTheComingLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 10 * 3600) ?? .current
        // 2025-10-13 09:00 local.
        let now = Date(timeIntervalSince1970: 1_760_310_000)
        let midnight = now - 9 * 3600
        #expect(CommittedSpendKey.nextDay(after: now, calendar: calendar) == midnight + 86_400)
        #expect(CommittedSpendKey.nextDay(after: midnight, calendar: calendar) == midnight + 86_400)
    }
}
