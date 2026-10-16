import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// The calls of the operations on a result (issue #41): `upscale_video`, `reframe`, `remove_background`, `dubbing`,
/// `voice_change` and `list_voices`, listed with their tool definitions from the catalog snapshot of 2026-10-15, and
/// every call checked against its `inputSchema`.
extension Network {
    @Suite struct VideoEdits {
        static let upscale = snapshotTool("upscale_video")
        static let removeBackground = snapshotTool("remove_background")
        static let reframe = snapshotTool("reframe")
        static let dubbing = snapshotTool("dubbing")
        static let voiceChange = snapshotTool("voice_change")
        static let listVoices = snapshotTool("list_voices")

        static func snapshotTool(_ name: String) -> JSONValue {
            (try? CatalogSnapshot.tool(name)) ?? [:]
        }

        static let upscaleEdit = VideoEdit(
            operation: .upscale(resolution: "4k", fps: 30, provider: .bytedance, width: 1280, height: 720),
            input: .job("3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"))
        static func reframing(seconds: Double) -> VideoEdit.Operation {
            .reframe(aspectRatio: "9:16", durationSeconds: seconds, resolution: "720p")
        }

        /// The `params` of each `tools/call`.
        static func params(_ stub: StubServer) -> [JSONValue?] {
            Account.calls(stub).map { $0["arguments"]?["params"] }
        }

        @Test func upscaleNamesTheVideoAsVideoIDAndReadsTheJob() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.upscale]) { _, _ in
                ["results": [["id": "job-9"]], "request_id": "req-9"]
            }

            let generation = try await account.run(Self.upscaleEdit)

            #expect(generation.id == "job-9")
            #expect(generation.requestID == "req-9")
            let calls = Account.calls(stub)
            #expect(calls.map { $0["name"] } == ["upscale_video"])
            #expect(
                calls.first?["arguments"]
                    == [
                        "params": [
                            "video_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "provider": "bytedance",
                            "resolution": "4k", "fps": 30,
                            "width": 1280, "height": 720,
                        ]
                    ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func topazSendsNeitherFrameRateNorSize() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.upscale]) { _, _ in
                ["results": [["id": "job-2"]]]
            }
            let edit = VideoEdit(
                operation: .upscale(resolution: "2160p", fps: nil, provider: .topaz, width: nil, height: nil),
                input: .media("5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50"))

            _ = try await account.run(edit)

            #expect(
                Self.params(stub) == [
                    ["video_id": "5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50", "provider": "topaz", "resolution": "2160p"]
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        /// The operation tools take no `get_cost`, so `generate_video` is asked for the catalog model by the whole
        /// seconds; nothing is asked of the operation's own tool.
        @Test(arguments: [
            (VideoEdit.Operation.dub(language: "fra"), "dubbing"),
            (.changeVoice(voiceID: "v-1", voiceType: "preset"), "voice_change"),
            (.removeBackground, "video_background_remover"),
        ])
        func operationsAreQuotedThroughGenerateVideo(operation: VideoEdit.Operation, model: String) async throws {
            let tools = [Self.upscale, Self.removeBackground, Self.dubbing, Self.voiceChange]
            let (account, stub) = Account.account(tools: Account.fullSet + tools) { _, _ in
                ["cost": ["credits": 21, "credits_exact": 21]]
            }

            #expect(try await account.cost(of: operation, duration: 7.04) == 21)

            let calls = Account.calls(stub)
            #expect(calls.map { $0["name"] } == ["generate_video"])
            #expect(
                calls.first?["arguments"]?["params"] == ["model": .string(model), "get_cost": true, "duration": 7])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        /// The live server prices an upscale by its resolution and frame rate, so they go along.
        @Test func aByteDanceUpscaleIsQuotedWithItsResolutionAndFrameRate() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.upscale]) { _, _ in
                ["cost": ["credits": 15]]
            }
            let operation = VideoEdit.Operation.upscale(
                resolution: "4k", fps: 60, provider: .bytedance, width: 1, height: 1)

            #expect(try await account.cost(of: operation, duration: 10) == 15)
            #expect(
                Account.calls(stub).first?["arguments"]?["params"] == [
                    "model": "bytedance_video_upscale", "get_cost": true, "duration": 10, "resolution": "4k", "fps": 60,
                ])
        }

        /// Topaz has no cost estimation, and a length is needed for the others: no call, no price.
        @Test func topazAndAMissingLengthAreNotQuoted() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.upscale, Self.dubbing])
            let topaz = VideoEdit.Operation.upscale(
                resolution: "1080p", fps: nil, provider: .topaz, width: nil, height: nil)
            #expect(try await account.cost(of: topaz, duration: 10) == nil)
            #expect(try await account.cost(of: .dub(language: "fra")) == nil)
            #expect(Account.calls(stub).isEmpty)
        }

        /// An answer without a price, like Topaz's "does not support alpha v2 cost estimation", leaves it unknown.
        @Test func anAnswerWithoutAPriceIsNoPrice() async throws {
            let (account, _) = Account.account(tools: Account.fullSet + [Self.dubbing]) { _, _ in
                ["error": "dubbing backend request failed (422)"]
            }
            #expect(try await account.cost(of: .dub(language: "fra"), duration: 5) == nil)
        }

        @Test func removeBackgroundNamesAJobAsMediaID() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.removeBackground]) { _, _ in
                ["results": [["id": "job-3"]]]
            }

            #expect(
                try await account.run(
                    VideoEdit(operation: .removeBackground, input: .job("3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"))
                ).id == "job-3")
            #expect(Self.params(stub) == [["media_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "media_type": "video"]])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func reframeIsQuotedByLengthAndResolutionAlone() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.reframe]) { _, arguments in
                arguments["params"]?["get_cost"] == true
                    ? ["cost": ["credits": 30, "credits_exact": .number(29.5)]] : ["results": [["id": "job-5"]]]
            }

            #expect(try await account.cost(of: Self.reframing(seconds: 8)) == 29.5)
            #expect(
                try await account.run(
                    VideoEdit(
                        operation: Self.reframing(seconds: 8), input: .job("3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"))
                ).id
                    == "job-5")

            #expect(
                Self.params(stub) == [
                    ["get_cost": true, "duration_seconds": 8, "resolution": "720p"],
                    [
                        "medias": [["role": "video", "value": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"]],
                        "aspect_ratio": "9:16",
                    ],
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aReframeOverFifteenSecondsNamesItsLengthAndResolution() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.reframe]) { _, _ in
                ["results": [["id": "job-6"]]]
            }

            _ = try await account.run(
                VideoEdit(
                    operation: Self.reframing(seconds: 21.5), input: .media("8e4f2a17-9b3d-4c6a-a1e5-0d2c3b4a5f61")))

            #expect(
                Self.params(stub) == [
                    [
                        "medias": [["role": "video", "value": "8e4f2a17-9b3d-4c6a-a1e5-0d2c3b4a5f61"]],
                        "aspect_ratio": "9:16",
                        "duration_seconds": .number(21.5), "resolution": "720p",
                    ]
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aReframeWhoseSchemaDropsGetCostIsNotAsked() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [paramsTool("reframe", ["medias"])])
            #expect(try await account.cost(of: Self.reframing(seconds: 8)) == nil)
            #expect(Account.calls(stub).isEmpty)
        }

        @Test func dubbingAndVoiceChangeNameTheVideoAsVideoID() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.dubbing, Self.voiceChange]) { _, _ in
                ["results": [["id": "job-7"]]]
            }

            _ = try await account.run(
                VideoEdit(operation: .dub(language: "fra"), input: .job("3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17")))
            _ = try await account.run(
                VideoEdit(
                    operation: .changeVoice(voiceID: "v-1", voiceType: "element"),
                    input: .media("a2c4e6f8-1b3d-4f5a-8c7e-9d0b1a2c3e4f")))

            #expect(Account.calls(stub).map { $0["name"] } == ["dubbing", "voice_change"])
            #expect(
                Self.params(stub) == [
                    ["video_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "target_language": "fra"],
                    ["video_id": "a2c4e6f8-1b3d-4f5a-8c7e-9d0b1a2c3e4f", "voice_id": "v-1", "voice_type": "element"],
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aMissingToolIsReportedBeforeAnyCall() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet)
            await #expect(throws: HiggsfieldError.toolUnavailable("upscale_video")) {
                try await account.checkTool(for: Self.upscaleEdit.operation)
            }
            await #expect(throws: HiggsfieldError.toolUnavailable("dubbing")) {
                try await account.checkTool(for: .dub(language: "fra"))
            }
            #expect(try await account.cost(of: Self.reframing(seconds: 8)) == nil)
            #expect(Account.calls(stub).isEmpty)
        }

        @Test func anAnswerWithoutAJobIsNotARefusal() async throws {
            let (account, _) = Account.account(tools: Account.fullSet + [Self.upscale]) { _, _ in ["ok": true] }
            await #expect(throws: HiggsfieldError.server(status: 200)) { try await account.run(Self.upscaleEdit) }
        }

        @Test func aReasonIsARefusal() async throws {
            let (account, _) = Account.account(tools: Account.fullSet + [Self.upscale]) { _, _ in
                ["error": "Video too long"]
            }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Video too long")) {
                try await account.run(Self.upscaleEdit)
            }
        }

        @Test func voicesAreReadPageByPage() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.listVoices]) { _, arguments in
                arguments["cursor"] == nil
                    ? [
                        "voices": [
                            [
                                "voice_id": "v-1", "voice_type": "preset", "name": "Amber", "gender": "female",
                                "preview_url": "https://cdn.example/amber.mp3",
                                "logo_url": "https://cdn.example/amber.png",
                            ],
                            ["voice_id": "v-2", "voice_type": "element", "name": "Mine", "gender": .null],
                            ["name": "No ID"],
                        ],
                        "has_more": true, "next_cursor": "c-2",
                    ]
                    : [
                        "voices": [["voice_id": "v-3", "preview_url": "http://cdn.example/plain.mp3"]],
                        "has_more": false, "next_cursor": "c-3",
                    ]
            }

            let first = try await account.voices()
            let second = try await account.voices(cursor: first.nextCursor, size: 500)

            #expect(
                first.items == [
                    Voice(
                        id: "v-1", type: "preset", name: "Amber",
                        previewURL: URL(string: "https://cdn.example/amber.mp3")),
                    Voice(id: "v-2", type: "element", name: "Mine"),
                ])
            #expect(first.nextCursor == "c-2")
            // No type reads as built-in, no name as the ID, and only an https sample is kept.
            #expect(second.items == [Voice(id: "v-3", type: "preset", name: "v-3")])
            // `has_more: false` ends the list though a cursor came with it.
            #expect(second.nextCursor == nil)
            #expect(
                Account.calls(stub).map { $0["arguments"] } == [["size": 100], ["size": 100, "cursor": "c-2"]])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aVoiceListOfUnknownShapeIsRefused() async throws {
            let (account, _) = Account.account(tools: Account.fullSet + [Self.listVoices]) { _, _ in ["ok": true] }
            await #expect(throws: HiggsfieldError.self) { try await account.voices() }
        }
    }
}
