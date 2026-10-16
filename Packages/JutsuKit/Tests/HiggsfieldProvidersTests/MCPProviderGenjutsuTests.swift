import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Genjutsu Styles and the Motion Library, as `get_presets` served them on 2026-10-14.
    @Suite struct GenjutsuGalleries {
        static let presets = tool(
            "get_presets", "Search and browse reusable presets",
            ["source", "category", "preset_id", "initial_inputs", "cursor", "limit", "query"])
        static let execute = tool(
            "execute_preset", "Request execution of one published preset", ["source", "preset_id", "inputs"])
        static let tools = Provider.fullSet + [presets, execute]

        static let styleID = UUID(uuidString: "2B5B68C4-9253-4D79-9D05-81E7718D8D7A")!
        static let style: JSONValue = [
            "id": "genjutsu-style:2b5b68c4-9253-4d79-9d05-81e7718d8d7a", "name": "Knitted Yarn World",
            "thumbnail_url": "https://static-public-media.higgsfield.ai/restyle-presets/503426a7.webp",
            "preview_url": "https://static-public-media.higgsfield.ai/restyle-presets/5c2f5251.mp4",
        ]
        static let motion: JSONValue = [
            "id": "genjutsu:trending:846e6f7b-53c1-4132-8d0f-ca05bfa826c8", "name": "Studio Duo Exchange",
            "thumbnail_url": "https://cdn.higgsfield.ai/a.webp", "preview_url": "https://cdn.higgsfield.ai/a.mp4",
            "description":
                "Motion transfer reference for /genjutsu. Driving video: https://example.com/drive.mp4. Use …",
        ]

        static func restyle() -> JobSpec {
            var spec = Provider.spec(.restyle)
            spec.presetID = styleID
            spec.prompt = "warm"
            return spec
        }

        @Test func styleToolsAddRestyle() async throws {
            let (provider, _) = Provider.provider(tools: Self.tools)
            #expect(
                try await provider.capabilities().modes == [.motionTransfer, .objectSwap, .edit, .extend, .restyle])
        }

        @Test func stylesBecomePresetsAcrossPages() async throws {
            let (provider, stub) = Provider.provider(tools: Self.tools) { _, arguments in
                arguments["cursor"] == nil
                    ? ["items": [Self.style, Self.motion], "next_cursor": 1050]
                    : ["items": [], "next_cursor": 2050]
            }
            let presets = try await provider.presets()
            #expect(
                presets == [
                    StylePreset(
                        id: Self.styleID, name: "Knitted Yarn World",
                        previewURL: URL(
                            string: "https://static-public-media.higgsfield.ai/restyle-presets/503426a7.webp")!,
                        previewVideoURL: URL(
                            string: "https://static-public-media.higgsfield.ai/restyle-presets/5c2f5251.mp4"))
                ])
            #expect(
                Provider.calls(stub).map { $0["arguments"]?["category"] } == ["genjutsu-styles", "genjutsu-styles"])
        }

        @Test func restyleEstimateFollowsTheQuotes() async throws {
            let (provider, _) = Provider.provider(tools: Self.tools)
            var spec = Self.restyle()
            spec.source?.range = 0...8
            #expect(try await provider.estimate(spec) == .credits(58, isEstimate: true))
            spec.resolution = .p480
            #expect(try await provider.estimate(spec) == .credits(26, isEstimate: true))
        }

        @Test(arguments: [true, false])
        func pathologicalPresetPagingFailsInsteadOfLooping(repeatedCursor: Bool) async throws {
            let answering = mcpServer(tools: Self.tools)
            let stub = StubServer { request, earlier in
                guard request.json?["params"]?["name"] == "get_presets", let id = request.json?["id"] else {
                    return answering.respond(to: request)
                }
                // A finite stub keeps the pre-fix regression from looping forever.
                guard earlier < 60 else { return StubResponse(status: 502) }
                return .json([
                    "jsonrpc": "2.0", "id": id,
                    "result": [
                        "structuredContent": [
                            "items": [Self.style], "next_cursor": .number(Double(repeatedCursor ? 1050 : earlier)),
                        ]
                    ],
                ])
            }
            let provider = makeProvider(stub.session())
            await #expect(throws: ProviderError.server(status: 200)) { try await provider.presets() }
            #expect(Provider.calls(stub).count == (repeatedCursor ? 2 : 50))
        }

        @Test func restyleRunsTheStyleWithTheUploadedFiles() async throws {
            let (provider, stub) = Provider.provider(tools: Self.tools) { name, _ in
                name == "execute_preset" ? ["job_ids": ["job-9"]] : ["execution": ["cost_credits": .number(57.5)]]
            }
            #expect(
                try await provider.serverEstimate(Self.restyle(), inputs: Provider.inputs)
                    == .credits(57.5, isEstimate: false))
            let job = try await provider.submit(Self.restyle(), inputs: Provider.inputs, idempotencyKey: UUID())
            #expect(job.requestID == "job-9")
            let run = try #require(Provider.calls(stub).last)
            #expect(run["name"] == "execute_preset")
            #expect(
                run["arguments"]
                    == [
                        "source": "genjutsu", "preset_id": "genjutsu-style:2b5b68c4-9253-4d79-9d05-81e7718d8d7a",
                        "inputs": [
                            "video": ["video-1"], "references": ["image-1"], "resolution": "720p", "prompt": "warm",
                        ],
                    ])
        }

        @Test func noQuoteLeavesTheEstimate() async throws {
            let (provider, _) = Provider.provider(tools: Self.tools) { _, _ in ["execution": ["available": true]] }
            #expect(try await provider.serverEstimate(Self.restyle(), inputs: Provider.inputs) == nil)
        }

        @Test func motionLibraryKeepsEntriesWithADrivingVideo() async throws {
            let (provider, stub) = Provider.provider(tools: Self.tools) { _, _ in
                ["items": [Self.motion, Self.style], "next_cursor": 1003]
            }
            let page = try await provider.motionPresets(on: .trending, after: nil)
            #expect(
                page.items == [
                    MotionPreset(
                        id: "genjutsu:trending:846e6f7b-53c1-4132-8d0f-ca05bfa826c8", name: "Studio Duo Exchange",
                        videoURL: URL(string: "https://example.com/drive.mp4")!,
                        thumbnailURL: URL(string: "https://cdn.higgsfield.ai/a.webp"),
                        previewURL: URL(string: "https://cdn.higgsfield.ai/a.mp4"), exampleMode: .motionTransfer)
                ])
            let next = try #require(page.nextCursor)
            _ = try await provider.motionPresets(on: .trending, after: next)
            #expect(Provider.calls(stub).last?["arguments"]?["cursor"] == 1003)
            #expect(Provider.calls(stub).first?["arguments"]?["category"] == "genjutsu-trending")
        }
    }
}
