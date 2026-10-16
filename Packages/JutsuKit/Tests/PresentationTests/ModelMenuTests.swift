import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct ModelMenuTests {
    static let klingO3 = VideoModel(rawValue: "klingO3VideoReference")

    static let apiKey: CreateContext = {
        var context = CreateFixture.apiKey
        context.capabilities = Capabilities(
            modes: Set(Mode.allCases), models: Set(VideoModel.allCases.filter(\.runsWithAPIKey)),
            resolutions: Set(Resolution.allCases), costUnit: .usd, maxConcurrency: nil)
        return context
    }()

    /// One list in the catalog's order, with Kling O3 Edit, which runs Motion's Edit task; each row has the price of a second of the form's jobs on that model and,
    /// since the longest lengths differ here, the longest the mode takes on it.
    @Test func theMenuIsOneListWithPriceAndLength() {
        CostText.$locale.withValue(.enUS) {
            let menu = CreateFixture.ready().modelMenu(in: Self.apiKey)
            #expect(
                menu.map(\.title) == [
                    "Genjutsu", "Seedance 2.5", "Kling 3.0", "Kling O3", "Kling O3 Edit", "Kling 2.6", "Wan 3.0",
                    "Wan 3.0 Prime",
                    "Wan 2.7", "Cinema Studio 4.0", "MiniMax H3",
                ])
            // At the form's 720p, or the nearest a model has (MiniMax H3's 2K). Kling O3, Kling O3 Edit and Cinema
            // Studio publish only a range (or a price naming no mode), so their rows give its top, rounded up. An API
            // key isn't offered MiniMax H3 Max.
            #expect(
                menu.map(\.detail) == [
                    "$0.681 / s · up to 30 s", "$0.555 / s · up to 30 s", "$0.126 / s · up to 30 s",
                    "up to $0.168 / s · up to 10 s", "up to $0.126 / s · up to 15 s", "$0.070 / s · up to 30 s",
                    "$0.100 / s · up to 30 s", "$0.140 / s · up to 30 s", "$0.100 / s · up to 10 s",
                    "up to $0.463 / s · up to 30 s", "$0.130 / s · up to 15 s",
                ])
        }
    }

    /// Credits have no rate table, and every model here takes 30 s, so the rows say nothing more than the name.
    @Test func onTheAccountEqualLengthsAreLeftOut() {
        var context = CreateContext(connection: .account(AccountInfo(credits: 100)))
        context.capabilities = Capabilities(
            modes: [.motionTransfer, .objectSwap], models: [.genjutsu, .klingMotionControl],
            resolutions: Set(Resolution.allCases), costUnit: .credits, maxConcurrency: nil)
        let menu = CreateFixture.ready().modelMenu(in: context)
        #expect(menu.map(\.model) == [.genjutsu, .klingMotionControl])
        #expect(menu.map(\.detail) == [nil, nil])
    }

    /// Kling O3 needs a prompt even with a source, and says so.
    @Test func klingO3AsksForAPrompt() throws {
        var form = CreateFixture.ready()
        form.model = try #require(Self.klingO3)
        #expect(form.promptTitle == "Prompt")
        #expect(form.blocker(isDraft: false, in: Self.apiKey) == "Write a prompt")
        form.prompt = "she spins"
        #expect(form.limits.duration == 3...10)
        #expect(form.ranges == [0...10])
        #expect(form.blocker(isDraft: false, in: Self.apiKey) == nil)
        #expect(form.showsKlingQuality && !form.showsVideoBackground && !form.offersDraft)
    }
}
