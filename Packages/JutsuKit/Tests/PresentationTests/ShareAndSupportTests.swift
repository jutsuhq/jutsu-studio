import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct SupportIDsTests {
    static let problemStates: [JobState] = [.failed(reason: .message("Server error")), .rejected]
    static let otherStates: [JobState] = [.processing, .done, .canceled, .paused(.byUser)]
    static var info: [String: Any] { ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "3"] }
    static var os: OperatingSystemVersion { OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0) }

    private func job(_ state: JobState, remote: RemoteJob?) -> Job {
        var job = JobFixture.job(state)
        job.remote = remote
        return job
    }

    private func line(_ state: JobState, remote: RemoteJob?) -> String? {
        SupportIDs.line(for: job(state, remote: remote), info: Self.info, os: Self.os)
    }

    @Test(arguments: problemStates) func failedOrRejectedJobGivesOneLine(state: JobState) {
        let remote = RemoteJob(requestID: "req-123", correlationID: "corr-9")
        let ids = line(state, remote: remote)
        #expect(ids == "request_id=req-123 correlation_id=corr-9 app=0.1.0 build=3 macos=15.1.0")
    }

    @Test func missingCorrelationIDStillGivesBothFields() {
        let ids = line(.rejected, remote: RemoteJob(requestID: "req-1"))
        #expect(ids == "request_id=req-1 correlation_id=none app=0.1.0 build=3 macos=15.1.0")
    }

    @Test func missingBundleInfoStillGivesEveryField() {
        let ids = SupportIDs.line(for: job(.rejected, remote: RemoteJob(requestID: "req-1")), info: nil, os: Self.os)
        #expect(ids == "request_id=req-1 correlation_id=none app=none build=none macos=15.1.0")
    }

    @Test func jobNeverSubmittedHasNoIDs() {
        #expect(line(.failed(reason: .message("Upload failed")), remote: nil) == nil)
    }

    @Test(arguments: otherStates) func otherStatesHaveNoCopyIDs(state: JobState) {
        #expect(line(state, remote: RemoteJob(requestID: "req-1")) == nil)
    }
}

@Suite struct LowCreditWarningTests {
    static let locale = Locale(identifier: "en_US")

    private func account(credits: Int?) -> ConnectionState {
        .account(AccountInfo(email: "a@example.com", credits: credits))
    }

    @Test func belowTheThresholdWarns() {
        let text = LowCreditWarning.text(for: account(credits: 49), threshold: 50, locale: Self.locale)
        #expect(text == "Low credits: 49 left")
    }

    @Test func atOrAboveTheThresholdIsQuiet() {
        #expect(LowCreditWarning.text(for: account(credits: 50), threshold: 50) == nil)
        #expect(LowCreditWarning.text(for: account(credits: 1_250), threshold: 50) == nil)
    }

    @Test func groupsLargeNumbers() {
        let text = LowCreditWarning.text(for: account(credits: 1_200), threshold: 5_000, locale: Self.locale)
        #expect(text == "Low credits: 1,200 left")
    }

    @Test func unknownCreditsAPIKeyAndNoConnectionAreQuiet() {
        #expect(LowCreditWarning.text(for: account(credits: nil), threshold: 50) == nil)
        #expect(LowCreditWarning.text(for: .apiKey(keyID: "key"), threshold: 50) == nil)
        #expect(LowCreditWarning.text(for: .none, threshold: 50) == nil)
    }

    @Test func defaultThresholdIsFifty() {
        #expect(AppSettings.defaultLowCreditThreshold == 50)
    }
}

@Suite struct ShortPreviewTests {
    @Test func takesTheFirstFiveSeconds() {
        #expect(ShortPreview.timeRange(duration: 12.4) == 0...5)
    }

    @Test func keepsAShorterClipWhole() {
        #expect(ShortPreview.timeRange(duration: 3.2) == 0...3.2)
    }

    @Test func clipWithoutLengthHasNoRange() {
        #expect(ShortPreview.timeRange(duration: 0) == nil)
        #expect(ShortPreview.timeRange(duration: .nan) == nil)
    }

    static let scaled: [(PixelSize, PixelSize)] = [
        (PixelSize(width: 1920, height: 1080), PixelSize(width: 854, height: 480)),
        (PixelSize(width: 1080, height: 1920), PixelSize(width: 480, height: 854)),
        (PixelSize(width: 1080, height: 1080), PixelSize(width: 480, height: 480)),
    ]

    @Test(arguments: scaled) func scalesTheShorterSideTo480(source: PixelSize, expected: PixelSize) {
        #expect(ShortPreview.renderSize(for: source) == expected)
    }

    @Test func neverUpscalesAndKeepsSidesEven() {
        #expect(ShortPreview.renderSize(for: PixelSize(width: 640, height: 360)) == PixelSize(width: 640, height: 360))
        let odd = ShortPreview.renderSize(for: PixelSize(width: 1281, height: 721))
        #expect(odd.map { $0.width % 2 == 0 && $0.height % 2 == 0 } == true)
        #expect(ShortPreview.renderSize(for: PixelSize(width: 0, height: 720)) == nil)
    }

    @Test func namesThePreviewAfterTheResult() {
        let url = URL(fileURLWithPath: "/out/2026-10-14_motion_1a2b.mov")
        #expect(ShortPreview.fileName(for: url) == "2026-10-14_motion_1a2b-preview.mp4")
    }

    @Test func fitsUnderTwoMegabytes() {
        #expect(ShortPreview.byteLimit <= 2_000_000)
    }
}
