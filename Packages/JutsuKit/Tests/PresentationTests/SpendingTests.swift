import Foundation
import JutsuCore
import Testing

@testable import Presentation

private func makeJob(
    _ state: JobState, cost: Cost, finishedAt: Date?, mode: Mode = .motionTransfer, resolution: Resolution = .p720,
    isDraft: Bool = false, duration: TimeInterval = 10
) -> Job {
    let source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 30,
        pixelSize: PixelSize(width: 1280, height: 720), range: 0...duration)
    let spec = JobSpec(mode: mode, source: source, resolution: resolution, isDraft: isDraft)
    var job = Job(
        spec: spec, providerKind: .apiKey, cost: cost, createdAt: finishedAt ?? Date(timeIntervalSince1970: 0))
    job.state = state
    job.finishedAt = finishedAt
    return job
}

@Suite struct SpendingSummaryTests {
    /// UTC+10, so local midnight is 14:00 UTC the day before.
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 10 * 3600)!
        return calendar
    }()
    /// 2025-10-13 09:00 local, 2025-10-12 23:00 UTC.
    let now = Date(timeIntervalSince1970: 1_760_310_000)
    var localMidnight: Date { now - 9 * 3600 }

    @Test func periodsStartAtLocalMidnight() {
        #expect(SpendingPeriod.today.start(now: now, calendar: calendar) == localMidnight)
        #expect(SpendingPeriod.week.start(now: now, calendar: calendar) == localMidnight - 6 * 86_400)
        #expect(SpendingPeriod.month.start(now: now, calendar: calendar) == localMidnight - 29 * 86_400)
    }

    @Test func todayFollowsTheUserTimeZoneNotUTC() {
        let jobs = [
            makeJob(.done, cost: .usd(1, isEstimate: false), finishedAt: localMidnight),
            makeJob(.done, cost: .usd(10, isEstimate: false), finishedAt: localMidnight - 1),
        ]
        let today = SpendingSummary(jobs, period: .today, now: now, calendar: calendar)
        #expect(today.charged == SpendTotal(usd: 1))
        #expect(today.chargedJobs == 1)
        let week = SpendingSummary(jobs, period: .week, now: now, calendar: calendar)
        #expect(week.charged == SpendTotal(usd: 11))
    }

    @Test func weekExcludesTheEighthDay() {
        let start = SpendingPeriod.week.start(now: now, calendar: calendar)
        let jobs = [
            makeJob(.done, cost: .usd(2, isEstimate: false), finishedAt: start),
            makeJob(.done, cost: .usd(5, isEstimate: false), finishedAt: start - 1),
        ]
        #expect(SpendingSummary(jobs, period: .week, now: now, calendar: calendar).charged == SpendTotal(usd: 2))
        #expect(SpendingSummary(jobs, period: .month, now: now, calendar: calendar).charged == SpendTotal(usd: 7))
    }

    @Test func failedRejectedAndCanceledAreNotCharged() {
        var downloadFailed = makeJob(
            .failed(reason: .message("download")), cost: .usd(3, isEstimate: false), finishedAt: now)
        downloadFailed.chargedAt = now
        let jobs = [
            makeJob(.done, cost: .usd(10, isEstimate: false), finishedAt: now),
            makeJob(.failed(reason: .message("x")), cost: .usd(4, isEstimate: false), finishedAt: now),
            makeJob(.rejected, cost: .credits(20, isEstimate: true), finishedAt: now),
            makeJob(.canceled, cost: .usd(1, isEstimate: false), finishedAt: now),
            downloadFailed,
        ]
        let summary = SpendingSummary(jobs, period: .today, now: now, calendar: calendar)
        #expect(summary.charged == SpendTotal(usd: 13))
        #expect(summary.chargedJobs == 2)
        #expect(summary.notCharged == SpendTotal(usd: 5, credits: 20))
        #expect(summary.notChargedJobs == 3)
    }

    @Test func activeJobsAreLeftOut() {
        let jobs = [
            makeJob(.processing, cost: .usd(9, isEstimate: true), finishedAt: nil),
            makeJob(.paused(.insufficientFunds), cost: .usd(9, isEstimate: true), finishedAt: nil),
        ]
        let summary = SpendingSummary(jobs, period: .today, now: now, calendar: calendar)
        #expect(summary.chargedJobs == 0 && summary.notChargedJobs == 0)
        #expect(summary.byMode.isEmpty)
    }

    @Test func usdAndCreditsAreKeptApart() {
        CostText.$locale.withValue(.enUS) {
            let jobs = [
                makeJob(.done, cost: .usd(Decimal(string: "3.816")!, isEstimate: false), finishedAt: now),
                makeJob(.done, cost: .credits(96, isEstimate: true), finishedAt: now),
            ]
            let summary = SpendingSummary(jobs, period: .today, now: now, calendar: calendar)
            #expect(summary.charged == SpendTotal(usd: Decimal(string: "3.816")!, credits: 96))
            #expect(summary.charged.text == "$3.82 · 96 cr")
        }
    }

    @Test func breaksDownChargedJobsByModeResolutionAndKind() {
        let jobs = [
            makeJob(
                .done, cost: .usd(1, isEstimate: false), finishedAt: now, mode: .restyle, resolution: .p480,
                isDraft: true),
            makeJob(.done, cost: .usd(2, isEstimate: false), finishedAt: now, mode: .restyle, resolution: .p1080),
            makeJob(
                .done, cost: .usd(4, isEstimate: false), finishedAt: now, mode: .motionTransfer, resolution: .p1080),
            makeJob(
                .failed(reason: .message("x")), cost: .usd(8, isEstimate: false), finishedAt: now, mode: .objectSwap),
        ]
        let summary = SpendingSummary(jobs, period: .today, now: now, calendar: calendar)
        #expect(
            summary.byMode == [
                SpendLine(title: "Motion transfer", jobs: 1, total: SpendTotal(usd: 4)),
                SpendLine(title: "Restyle", jobs: 2, total: SpendTotal(usd: 3)),
            ])
        #expect(
            summary.byResolution == [
                SpendLine(title: "480p", jobs: 1, total: SpendTotal(usd: 1)),
                SpendLine(title: "1080p", jobs: 2, total: SpendTotal(usd: 6)),
            ])
        #expect(
            summary.byKind == [
                SpendLine(title: "Draft", jobs: 1, total: SpendTotal(usd: 1)),
                SpendLine(title: "Final", jobs: 2, total: SpendTotal(usd: 6)),
            ])
    }

    @Test func totalTextShowsZeroDollarsWhenNothingWasSpent() {
        CostText.$locale.withValue(.enUS) {
            #expect(SpendTotal().text == "$0.00")
            #expect(SpendTotal(credits: 1_200).text == "1200 cr")
        }
    }

    @Test func chargedRuleMatchesTheDailyCap() {
        var canceled = makeJob(.canceled, cost: .usd(7, isEstimate: false), finishedAt: now)
        canceled.chargedAt = now
        let jobs = [
            canceled, makeJob(.done, cost: .usd(10, isEstimate: false), finishedAt: now),
            makeJob(.failed(reason: .message("x")), cost: .usd(50, isEstimate: false), finishedAt: now),
        ]
        let summary = SpendingSummary(jobs, period: .today, now: now, calendar: calendar)
        #expect(summary.charged.usd == DailySpend.committed(jobs, on: now, calendar: calendar))
    }
}

@Suite struct SpendingCSVTests {
    let utcPlus2 = TimeZone(secondsFromGMT: 2 * 3600)!
    /// 2025-10-13 12:00 UTC.
    let noon = Date(timeIntervalSince1970: 1_760_356_800)

    @Test func writesHeaderAndOneRowPerFinishedJobOldestFirst() {
        var done = makeJob(
            .done, cost: .usd(Decimal(string: "3.816")!, isEstimate: false), finishedAt: noon, mode: .restyle,
            resolution: .p1080, duration: 11.2)
        done.remote = RemoteJob(requestID: "req-1")
        let draft = makeJob(
            .rejected, cost: .credits(40, isEstimate: true), finishedAt: noon - 3600, resolution: .p480, isDraft: true)
        let active = makeJob(.processing, cost: .usd(1, isEstimate: true), finishedAt: nil)

        let csv = SpendingCSV.csv([done, active, draft], timeZone: utcPlus2)
        #expect(
            csv == "Date,Mode,Resolution,Draft,Billed seconds,Estimated cost,Currency,State,Charged,Request ID\r\n"
                + "2025-10-13T13:00:00+02:00,Motion transfer,480p,Yes,10,40,credits,Rejected,No,\r\n"
                + "2025-10-13T14:00:00+02:00,Restyle,1080p,No,12,3.816,USD,Done,Yes,req-1\r\n")
    }

    @Test func chargedDownloadFailureIsMarkedCharged() {
        var failed = makeJob(.failed(reason: .message("download")), cost: .usd(2, isEstimate: false), finishedAt: noon)
        failed.chargedAt = noon
        let csv = SpendingCSV.csv([failed], timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(csv.hasSuffix("2025-10-13T12:00:00Z,Motion transfer,720p,No,10,2,USD,Failed,Yes,\r\n"))
    }

    @Test func escapesFieldsPerRFC4180() {
        #expect(SpendingCSV.escape("plain") == "plain")
        #expect(SpendingCSV.escape("a,b") == "\"a,b\"")
        #expect(SpendingCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(SpendingCSV.escape("two\nlines") == "\"two\nlines\"")
        #expect(SpendingCSV.escape("cr\r\nlf") == "\"cr\r\nlf\"")
        #expect(SpendingCSV.line(["a", "b,c", ""]) == "a,\"b,c\",\r\n")
    }

    @Test func requestIDWithACommaIsQuoted() {
        var job = makeJob(.done, cost: .usd(1, isEstimate: false), finishedAt: noon)
        job.remote = RemoteJob(requestID: "a,\"b\"")
        let csv = SpendingCSV.csv([job], timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(csv.hasSuffix(",Done,Yes,\"a,\"\"b\"\"\"\r\n"))
    }

    @Test func emptyLibraryIsJustTheHeader() {
        #expect(SpendingCSV.csv([]) == SpendingCSV.header.joined(separator: ",") + "\r\n")
    }

    @Test func defaultFileNameUsesTheLocalDate() {
        let lateEvening = Date(timeIntervalSince1970: 1_760_396_400)  // 2025-10-13 23:00 UTC
        #expect(SpendingCSV.defaultFileName(now: lateEvening, timeZone: utcPlus2) == "Jutsu Studio spending 2025-10-14")
    }
}
