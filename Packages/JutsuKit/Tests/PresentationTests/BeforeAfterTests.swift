import Foundation
import Testing

@testable import Presentation

struct CompareDividerTests {
    @Test func startsInTheMiddle() {
        #expect(CompareDivider().position == 0.5)
        #expect(CompareDivider().percentText == "50%")
    }

    @Test func clampsToTheWidth() {
        #expect(CompareDivider(position: -0.2).position == 0)
        #expect(CompareDivider(position: 1.4).position == 1)
        #expect(CompareDivider(position: .nan).position == 0.5)
    }

    @Test func followsADrag() {
        var divider = CompareDivider()
        divider.drag(to: 75, width: 300)
        #expect(divider.position == 0.25)
        divider.drag(to: 400, width: 300)
        #expect(divider.position == 1)
        divider.drag(to: -10, width: 300)
        #expect(divider.position == 0)
    }

    @Test func ignoresADragBeforeLayout() {
        var divider = CompareDivider(position: 0.3)
        divider.drag(to: 10, width: 0)
        #expect(divider.position == 0.3)
    }

    @Test func arrowKeysStepAndStopAtTheEdges() {
        var divider = CompareDivider(position: 0.5)
        divider.nudge(by: 1)
        #expect(abs(divider.position - 0.55) < 1e-9)
        #expect(divider.percentText == "55%")
        divider.nudge(by: -20)
        #expect(divider.position == 0)
        divider.nudge(by: 40)
        #expect(divider.position == 1)
        #expect(divider.percentText == "100%")
    }
}

struct CompareClockTests {
    @Test func offsetsByTheSourceRange() {
        let clock = CompareClock(sourceRange: 4...10)
        #expect(clock.sourceTime(atResult: 0) == 4)
        #expect(clock.sourceTime(atResult: 2.5) == 6.5)
    }

    @Test func holdsAtTheRangeEnd() {
        let clock = CompareClock(sourceRange: 4...10)
        #expect(clock.sourceTime(atResult: 8) == 10)
        #expect(clock.sourceTime(atResult: -1) == 4)
    }

    @Test func wholeSourceWithoutARange() {
        #expect(CompareClock(sourceRange: nil).sourceTime(atResult: 3) == 3)
    }

    @Test func correctsOnlyPastTheTolerance() {
        let clock = CompareClock(sourceRange: 4...10)
        #expect(clock.correction(resultTime: 2, sourceTime: 6.05) == nil)
        #expect(clock.correction(resultTime: 2, sourceTime: 5.95) == nil)
        #expect(clock.correction(resultTime: 2, sourceTime: 6.3) == 6)
        #expect(clock.correction(resultTime: 2, sourceTime: 5.5) == 6)
    }

    @Test func noCorrectionAfterTheSourceEnded() {
        let clock = CompareClock(sourceRange: 4...10)
        #expect(clock.correction(resultTime: 7, sourceTime: 10) == nil)
    }

    @Test func noCorrectionWhileATimeIsUnknown() {
        let clock = CompareClock(sourceRange: 4...10)
        #expect(clock.correction(resultTime: .nan, sourceTime: 5) == nil)
        #expect(clock.correction(resultTime: 1, sourceTime: .nan) == nil)
    }
}

struct AboutContentTests {
    @Test func versionAndBuild() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
        #expect(AboutContent.versionText(info: info) == "Version 0.1.0 (1)")
    }

    @Test func buildEqualToVersionIsShownOnce() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1.0"]
        #expect(AboutContent.versionText(info: info) == "Version 1.0")
    }

    @Test func missingKeys() {
        #expect(AboutContent.versionText(info: ["CFBundleVersion": "7"]) == "Build 7")
        #expect(AboutContent.versionText(info: nil) == "Development build")
    }
}
