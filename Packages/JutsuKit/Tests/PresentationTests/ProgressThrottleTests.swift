import Testing

@testable import Presentation

@Suite struct ProgressThrottleTests {
    @Test func passesTheFirstReportAndEachNewWholePercent() {
        let throttle = ProgressThrottle()
        let passed = [0, 0.001, 0.009, 0.01, 0.015, 0.02, 0.5, 0.505, 1].filter { throttle.admits($0) }
        #expect(passed == [0, 0.01, 0.02, 0.5, 1])
    }

    @Test func passesAnUnknownSizeOnceAndItsChangeToAKnownOne() {
        let throttle = ProgressThrottle()
        let reports: [Double?] = [nil, nil, 0.3, 0.301, nil]
        #expect(reports.map { throttle.admits($0) } == [true, false, true, false, true])
    }
}
