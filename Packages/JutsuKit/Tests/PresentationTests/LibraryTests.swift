import Foundation
import JutsuCore
import Testing

@testable import Presentation

private func dec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0
}

enum LibraryFixture {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func item(
        mode: Mode = .restyle, source: String = "rooftop.mov", range: ClosedRange<TimeInterval> = 4...10,
        resolution: Resolution = .p480, isDraft: Bool = true, prompt: String = "", references: Int = 0,
        cost: Cost = .usd(dec("1.908"), isEstimate: false), via: ProviderKind = .apiKey,
        presetName: String? = nil, minutesAgo: Double = 36, queuedMinutesAgo: Double = 60
    ) -> LibraryItemModel {
        let clip = SourceClip(
            fileURL: URL(fileURLWithPath: "/home/me/Movies/\(source)"), duration: 30,
            pixelSize: PixelSize(width: 1920, height: 1080), range: range)
        let spec = JobSpec(
            mode: mode, source: clip,
            references: (0..<references).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref\($0).png")) },
            presetID: presetName == nil ? nil : UUID(), prompt: prompt, resolution: resolution, isDraft: isDraft)
        var job = Job(
            spec: spec, providerKind: via, cost: cost, createdAt: now.addingTimeInterval(-queuedMinutesAgo * 60))
        job.state = .done
        job.finishedAt = now.addingTimeInterval(-minutesAgo * 60)
        job.outputFile = URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/out.mp4")
        job.remote = RemoteJob(requestID: "req-123", correlationID: "corr-9")
        return LibraryItemModel(job: job, presetName: presetName)
    }
}

@Suite struct LibraryFilterTests {
    let items = [
        LibraryFixture.item(mode: .restyle, resolution: .p480, isDraft: true, presetName: "Claymation"),
        LibraryFixture.item(
            mode: .motionTransfer, source: "dance.mp4", resolution: .p720, isDraft: false,
            prompt: "Keep the Camera move"),
        LibraryFixture.item(mode: .objectSwap, source: "sneaker.mov", resolution: .p1080, isDraft: false),
    ]

    @Test func emptyFilterKeepsEverythingInOrder() {
        #expect(LibraryFilter().apply(items) == items)
        #expect(!LibraryFilter().isActive)
    }

    @Test func filtersByModeResolutionAndKind() {
        #expect(LibraryFilter(mode: .objectSwap).apply(items) == [items[2]])
        #expect(LibraryFilter(resolution: .p720).apply(items) == [items[1]])
        #expect(LibraryFilter(finish: .drafts).apply(items) == [items[0]])
        #expect(LibraryFilter(finish: .finals).apply(items) == [items[1], items[2]])
        #expect(LibraryFilter(mode: .restyle, finish: .finals).apply(items).isEmpty)
    }

    @Test func searchCoversPromptAndTitleCaseInsensitively() {
        #expect(LibraryFilter(query: "camera").apply(items) == [items[1]])
        #expect(LibraryFilter(query: "  CLAY ").apply(items) == [items[0]])
        #expect(LibraryFilter(query: "sneaker").apply(items) == [items[2]])
        #expect(LibraryFilter(query: "motion").apply(items) == [items[1]])
        #expect(LibraryFilter(query: "nothing like it").apply(items).isEmpty)
        #expect(LibraryFilter(query: "   ").apply(items) == items)
    }
}

@Suite struct LibraryCardTests {
    @Test func titleUsesPresetNameOrModeTitle() {
        #expect(LibraryFixture.item(presetName: "Claymation").title == "rooftop · Claymation")
        #expect(LibraryFixture.item(mode: .motionTransfer, source: "dance.mp4").title == "dance · Motion transfer")
    }

    @Test func subtitleInUSDAndCredits() {
        CostText.$locale.withValue(.enUS) {
            let now = LibraryFixture.now
            #expect(LibraryFixture.item().subtitle(now: now) == "480p · $1.91 · 36 min ago")
            let credits = LibraryFixture.item(
                resolution: .p720, cost: .credits(48, isEstimate: true), via: .account, minutesAgo: 1560)
            #expect(credits.subtitle(now: now) == "720p · 48 cr · 1 d ago")
            #expect(LibraryFixture.item(isDraft: false, minutesAgo: 0.2).headline(now: now) == "just now · Final")
            #expect(LibraryFixture.item(minutesAgo: 72).headline(now: now) == "1 h ago · Draft")
        }
    }

    @Test func tagsAndDuration() {
        let item = LibraryFixture.item(mode: .objectSwap, range: 0...9.6)
        #expect(item.modeTag == "Swap")
        #expect(item.durationText == "10 s")
    }

    @Test func accessibilityLabelReadsTagsAndBadges() {
        CostText.$locale.withValue(.enUS) {
            let now = LibraryFixture.now
            var item = LibraryFixture.item(presetName: "Claymation")
            #expect(
                item.accessibilityLabel(now: now)
                    == "rooftop · Claymation, Restyle, Draft, 6 s, 480p · $1.91 · 36 min ago")
            item.isStarred = true
            item.job.spec.isDraft = false
            let starred = "rooftop · Claymation, Restyle, 6 s, 480p · $1.91 · 36 min ago, Starred"
            #expect(item.accessibilityLabel(now: now) == starred)

            let remote = LibraryItemModel(history: HistoryFixture.item("gen-1", isLiked: true))
            #expect(remote.accessibilityLabel(now: now).hasSuffix(", Starred, On Higgsfield, not downloaded yet"))
            #expect(!remote.accessibilityLabel(now: now).contains("$"))
        }
    }
}

@Suite struct LibraryDetailTests {
    @Test func factsListOnlyWhatWasUsed() {
        CostText.$locale.withValue(.enUS) {
            let item = LibraryFixture.item(prompt: "Rain on the windows", references: 2, presetName: "Film Noir")
            #expect(item.facts == ["Restyle", "Film Noir", "480p", "6 s", "2 images"])
            #expect(LibraryFixture.item(references: 1).facts == ["Restyle", "480p", "6 s", "1 image"])
            #expect(LibraryFixture.item().rangeText == "00:04.0 – 00:10.0")
        }
    }

    @Test func billingSummaryInUSDAndCredits() {
        CostText.$locale.withValue(.enUS) {
            #expect(LibraryFixture.item().billingSummary == "$1.91 · Estimate · 6 s × $0.318 · API key")
            let credits = LibraryFixture.item(cost: .credits(24, isEstimate: true), via: .account)
            #expect(credits.billingSummary == "24 cr · Estimate · 6 s × 4 cr · Higgsfield account")
            // An account price that isn't an estimate is Higgsfield's quote before upload.
            let quoted = LibraryFixture.item(cost: .credits(24, isEstimate: false), via: .account)
            #expect(quoted.billingSummary == "24 cr · Price from Higgsfield · 6 s × 4 cr · Higgsfield account")
            let odd = LibraryFixture.item(range: 0...4, cost: .credits(18, isEstimate: false), via: .account)
            #expect(odd.billedText == "4 s × 4.5 cr")
        }
    }

    @Test func aspectRatioOfTheSource() {
        var item = LibraryFixture.item()
        #expect(item.aspectRatio == 1920.0 / 1080.0)
        item.job.spec.source?.pixelSize = PixelSize(width: 0, height: 0)
        #expect(item.aspectRatio == nil)
    }

    @Test func playbackIsLocalOnly() {
        var item = LibraryFixture.item()
        #expect(item.playback(.result)?.range == nil)
        #expect(item.playback(.source) == PlaybackClip(url: item.spec.source!.fileURL, range: 4...10))
        item.job.spec.source?.bookmark = Data([7])
        #expect(item.playback(.source)?.bookmark == Data([7]))
        item.job.outputFile = URL(string: "https://cdn.example.com/out.mp4")
        #expect(item.playback(.result) == nil)
        item.job.outputFile = nil
        #expect(item.playback(.result) == nil)
    }

    @Test func formats() {
        CostText.$locale.withValue(.enUS) {
            #expect(LibraryFormat.timecode(64.46) == "01:04.5")
            #expect(LibraryFormat.timecode(0) == "00:00.0")
            #expect(LibraryFormat.usd(2, fractionDigits: 2) == "$2.00")
            #expect(LibraryFormat.usd(dec("0.3175"), fractionDigits: 3) == "$0.318")
            #expect(
                LibraryFormat.ago(LibraryFixture.now.addingTimeInterval(-200 * 60), now: LibraryFixture.now)
                    == "3 h ago")
        }
    }
}

@Suite struct LibraryFollowUpTests {
    let pricing: Pricing

    init() throws {
        // Genjutsu at $0.318, $0.681 and $1.632 per second.
        pricing = try Pricing.bundled()
    }

    @Test func finalSpecKeepsInputsAndDropsDraft() {
        let item = LibraryFixture.item(prompt: "keep", references: 1, presetName: "Claymation")
        let final = item.finalSpec(at: .p1080)
        #expect(final.resolution == .p1080)
        #expect(!final.isDraft)
        #expect(final.source == item.spec.source)
        #expect(final.references == item.spec.references)
        #expect(final.presetID == item.spec.presetID)
        #expect(final.prompt == "keep")
        #expect(item.canRenderFinal)
        #expect(!LibraryFixture.item(isDraft: false).canRenderFinal)
    }

    @Test func finalPriceForAnAPIKeyOnly() {
        let item = LibraryFixture.item()
        #expect(
            item.finalPrice(at: .p720, pricing: pricing, connection: .apiKey) == .usd(dec("4.086"), isEstimate: false))
        #expect(
            item.finalPrice(at: .p1080, pricing: pricing, connection: .apiKey) == .usd(dec("9.792"), isEstimate: false))
        #expect(item.finalPrice(at: .p720, pricing: pricing, connection: .account) == nil)
        #expect(item.finalPrice(at: .p720, pricing: nil, connection: .apiKey) == nil)
    }
}

@Suite struct LibraryTimingTests {
    @Test func showsTheStageTimesThatWereRecorded() {
        var item = LibraryFixture.item()
        #expect(item.timingSummary == nil)

        let created = item.job.createdAt
        item.job.submittedAt = created.addingTimeInterval(30)
        item.job.processingAt = created.addingTimeInterval(125)
        #expect(item.timingSummary == "Queue wait 2:05")

        item.job.chargedAt = created.addingTimeInterval(197)
        #expect(item.timingSummary == "Queue wait 2:05 · Processing 1:12")
    }
}
