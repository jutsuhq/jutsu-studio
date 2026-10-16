import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// Entries as `get_presets` gave them on 2026-10-14, trimmed to the keys the client reads.
enum GenjutsuFixture {
    static let motion: JSONValue = [
        "id": "genjutsu:27182599-2cee-4b27-be1a-d13e9d713d37", "name": "Countryside Duo", "kind": "genjutsu-motion",
        "thumbnail_url": "https://cdn.higgsfield.ai/higgsfield_multiplier_video_explore_variant/54b6f52b.webp",
        "preview_url": "https://cdn.higgsfield.ai/genjutsu/preview/genjutsu-h264-600-v1/90d01517.mp4",
        "description": """
        Object replacement reference for /genjutsu. Driving video: \
        https://d2ol7oe51mr4n9.cloudfront.net/content_user_id/baed0aeb.mp4. Use the user's reference image, \
        never the catalog example's character.
        """,
    ]

    static let trending: JSONValue = [
        "id": "genjutsu:trending:846e6f7b-53c1-4132-8d0f-ca05bfa826c8", "name": "Studio Duo Exchange",
        "description": "Motion transfer reference for /genjutsu. Driving video: https://example.com/a.mp4. Use …",
    ]

    static let style: JSONValue = [
        "id": "genjutsu-style:2b5b68c4-9253-4d79-9d05-81e7718d8d7a", "name": "Knitted Yarn World",
        "kind": "genjutsu-style",
        "thumbnail_url": "https://static-public-media.higgsfield.ai/restyle-presets/503426a7.webp",
        "preview_url": "https://static-public-media.higgsfield.ai/restyle-presets/5c2f5251.mp4",
        "description": "Genjutsu Style (Restyle): redraws the user's own video in this look.",
    ]

    static let run = StyleRun(
        styleID: "genjutsu-style:2b5b68c4-9253-4d79-9d05-81e7718d8d7a", videoID: "video-1", imageIDs: ["image-1"],
        prompt: "warm light", resolution: "720p")

    static let tools =
        Network.Account.fullSet + [
            tool(
                "get_presets", "Search and browse reusable presets",
                ["source", "category", "preset_id", "initial_inputs", "cursor", "limit", "query"]),
            tool("execute_preset", "Request execution of one published preset", ["source", "preset_id", "inputs"]),
        ]
}

@Suite struct GenjutsuPresetTests {
    @Test func motionEntryNamesItsDrivingVideoAndModel() throws {
        let preset = try #require(GenjutsuPreset(GenjutsuFixture.motion))
        #expect(
            preset.drivingVideoURL == URL(string: "https://d2ol7oe51mr4n9.cloudfront.net/content_user_id/baed0aeb.mp4"))
        #expect(preset.exampleModel == .replaceObject)
        #expect(preset.uuid == UUID(uuidString: "27182599-2cee-4b27-be1a-d13e9d713d37"))
        #expect(preset.previewURL?.pathExtension == "mp4")
    }

    @Test func trendingIDsKeepTheirUUIDAtTheEnd() throws {
        let preset = try #require(GenjutsuPreset(GenjutsuFixture.trending))
        #expect(preset.uuid == UUID(uuidString: "846e6f7b-53c1-4132-8d0f-ca05bfa826c8"))
        #expect(preset.exampleModel == .motionControl)
        #expect(preset.thumbnailURL == nil)
    }

    @Test func styleHasNoDrivingVideo() throws {
        let preset = try #require(GenjutsuPreset(GenjutsuFixture.style))
        #expect(preset.drivingVideoURL == nil)
        #expect(preset.exampleModel == nil)
    }

    @Test func entriesWithoutIDOrNameAreLeftOut() throws {
        let page = try #require(
            GenjutsuPresetPage([
                "items": [GenjutsuFixture.style, ["name": "No ID"], ["id": "x"]], "next_cursor": .null,
            ]))
        #expect(page.items.map(\.name) == ["Knitted Yarn World"])
        #expect(page.nextCursor == nil)
        #expect(GenjutsuPresetPage(["presets": []]) == nil)
    }

    @Test func styleInputsLeaveOutWhatIsEmpty() {
        var run = GenjutsuFixture.run
        #expect(
            run.inputs
                == [
                    "video": ["video-1"], "references": ["image-1"], "resolution": "720p", "prompt": "warm light",
                ])
        run.imageIDs = []
        run.prompt = ""
        #expect(run.inputs == ["video": ["video-1"], "resolution": "720p"])
    }

    @Test(arguments: [
        (
            #"{"content":[{"type":"text","text":"readiness:\n  ready: true\n  issues: []\n  cost_credits: 57.5\nA bare preset"}]}"#,
            57.5
        ),
        (#"{"content":[{"type":"text","text":"x"}],"structuredContent":{"execution":{"cost_credits":12}}}"#, 12),
        // A Style's priced detail in TOON, the price only in the text and nested under `execution` (the live quote
        // for 12 s at 720p on 2026-10-15 was 85.5).
        (
            #"""
            {"content":[{"type":"text","text":"preset:\n  id: style_1\n  name: Film Noir\ninputs[2]{name,required}:\n  video,true\n  resolution,false\nexecution:\n  tool: execute_preset\n  readiness:\n    ready: true\n    issues[0]:\n  cost_credits: 85.5\n  currency: credits"}],"structuredContent":{"preset":{"id":"style_1"}}}
            """#,
            85.5
        ),
    ])
    func quoteIsReadFromStructuredContentOrText(json: String, credits: Double) throws {
        let result = try JSONDecoder().decode(MCPToolResult.self, from: Data(json.utf8))
        #expect(PresetQuote.credits(in: result) == credits)
    }

    @Test func noQuoteWhenTheInputsAreNotReady() throws {
        let json = #"{"content":[{"type":"text","text":"readiness:\n  ready: false\nPrice unavailable."}]}"#
        #expect(PresetQuote.credits(in: try JSONDecoder().decode(MCPToolResult.self, from: Data(json.utf8))) == nil)
    }

    @Test(arguments: [
        JSONValue.object(["job_ids": ["job-1"]]), ["job_ids": [["id": "job-1"]]], ["jobs": [["id": "job-1"]]],
        ["results": [["id": "job-1"]]], ["job_id": "job-1"],
    ])
    func everyDescribedJobShapeIsRead(value: JSONValue) {
        #expect(PresetQuote.jobID(in: value) == "job-1")
    }
}

extension Network {
    @Suite struct Genjutsu {
        static func account(
            call: @escaping @Sendable (String, JSONValue) -> JSONValue
        ) -> (HiggsfieldAccount, StubServer) {
            Network.Account.account(tools: GenjutsuFixture.tools, call: call)
        }

        @Test func galleryPageAsksForTheCategory() async throws {
            let (account, stub) = Self.account { _, _ in ["items": [GenjutsuFixture.motion], "next_cursor": 1003] }
            let page = try await account.genjutsuPresets(.trending, cursor: 3, limit: 99)
            #expect(page.items.map(\.name) == ["Countryside Duo"])
            #expect(page.nextCursor == 1003)
            #expect(
                Network.Account.calls(stub).first?["arguments"]
                    == ["source": "genjutsu", "category": "genjutsu-trending", "limit": 50, "cursor": 3])
        }

        @Test func stylesNeedTheirTools() async throws {
            let (account, _) = Self.account { _, _ in [:] }
            try await account.refreshTools()
            #expect(await account.canRunStyles)
            let (plain, _) = Network.Account.account()
            try await plain.refreshTools()
            #expect(await !plain.canRunStyles)
        }

        @Test func runSendsTheStyleAndInputs() async throws {
            let (account, stub) = Self.account { _, _ in ["job_ids": ["job-1"]] }
            #expect(try await account.run(GenjutsuFixture.run) == Generation(id: "job-1", requestID: nil))
            let call = try #require(Network.Account.calls(stub).first)
            #expect(call["name"] == "execute_preset")
            #expect(call["arguments"]?["preset_id"] == .string(GenjutsuFixture.run.styleID))
            #expect(call["arguments"]?["inputs"] == GenjutsuFixture.run.inputs)
        }

        @Test func anUnreadableRunReplyIsNotARefusal() async throws {
            let (unreadable, _) = Self.account { _, _ in ["status": "ok"] }
            await #expect(throws: HiggsfieldError.server(status: 200)) { try await unreadable.run(GenjutsuFixture.run) }
            let (declined, _) = Self.account { _, _ in ["error": "Video too short"] }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Video too short")) {
                try await declined.run(GenjutsuFixture.run)
            }
        }

        @Test func costOpensTheFilledDetail() async throws {
            let (account, stub) = Self.account { _, _ in ["execution": ["cost_credits": .number(57.5)]] }
            #expect(try await account.cost(of: GenjutsuFixture.run) == 57.5)
            let arguments = Network.Account.calls(stub).first?["arguments"]
            #expect(arguments?["initial_inputs"] == GenjutsuFixture.run.inputs)
            #expect(arguments?["category"] == "all")
        }
    }
}
