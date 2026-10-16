import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// The operations on a result on the account (issue #41), with the tool definitions of the catalog snapshot of
    /// 2026-10-15; every call is checked against its `inputSchema`.
    @Suite struct PostOperations {
        static let tools =
            Provider.fullSet
            + ["upscale_video", "remove_background", "reframe", "dubbing", "voice_change", "list_voices"].map {
                (try? CatalogSnapshot.tool($0)) ?? [:]
            }
        static let uploaded = RemoteInputs(
            video: RemoteAsset(url: URL(fileURLWithPath: "/in.mp4"), id: "5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50"),
            images: [])

        static func spec(
            _ action: PostAction, jobID: String? = "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", seconds: TimeInterval = 10
        ) -> JobSpec {
            var spec = Provider.spec(.motionTransfer)
            spec.source?.range = 0...seconds
            spec.operation = PostOperation(action: action, sourceJobID: jobID)
            return spec
        }

        static let upscale = PostAction.upscale(UpscaleOptions(target: .k4, frameRate: .fps60, engine: .standard))
        static let voice = VoiceChoice(id: "v-1", type: "element", name: "Mine")
        static let noInputs = RemoteInputs(video: nil, images: [])

        static func provider(
            call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        ) -> (HiggsfieldMCPProvider, StubServer) {
            Provider.provider(tools: tools, call: call)
        }

        static func params(_ stub: StubServer) -> [JSONValue?] {
            Provider.calls(stub).map { $0["arguments"]?["params"] }
        }

        /// Quoted through `generate_video` by the result's length, resolution and frame rate.
        @Test func upscaleNamesTheResultByItsJobIDAndIsQuotedByItsLength() async throws {
            let (provider, stub) = Self.provider { name, _ in
                name == "upscale_video"
                    ? ["results": [["id": "job-2"]], "request_id": "req-2"] : ["cost": ["credits": 15]]
            }
            let spec = Self.spec(Self.upscale)

            #expect(try await provider.estimate(spec) == .credits(15, isEstimate: true))
            #expect(try await provider.serverEstimate(spec, inputs: Self.noInputs) == .credits(15, isEstimate: false))
            #expect(try await provider.submitIsIdempotent(spec) == false)
            let remote = try await provider.submit(spec, inputs: Self.noInputs, idempotencyKey: UUID())

            #expect(remote.requestID == "job-2")
            #expect(remote.correlationID == "req-2")
            #expect(Provider.calls(stub).map { $0["name"] } == ["generate_video", "generate_video", "upscale_video"])
            let quote: JSONValue = [
                "model": "bytedance_video_upscale", "get_cost": true, "duration": 10, "resolution": "4k", "fps": 60,
            ]
            #expect(
                Self.params(stub) == [
                    quote, quote,
                    [
                        "video_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "provider": "bytedance", "resolution": "4k",
                        "fps": 60, "width": 1280,
                        "height": 720,
                    ],
                ])
        }

        @Test func topazAt4KSends2160pAndNeitherSizeNorRate() async throws {
            let (provider, stub) = Self.provider { _, _ in ["results": [["id": "job-3"]]] }
            let spec = Self.spec(.upscale(UpscaleOptions(target: .k4, frameRate: .fps60, engine: .topaz)))

            _ = try await provider.submit(spec, inputs: Self.noInputs, idempotencyKey: UUID())

            #expect(
                Self.params(stub) == [
                    ["video_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "provider": "topaz", "resolution": "2160p"]
                ])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func upscalesTheToolCantTakeAreRefusedBeforeSending() async throws {
            let (provider, stub) = Self.provider()
            var unsized = Self.spec(Self.upscale)
            unsized.source?.pixelSize = PixelSize(width: 0, height: 0)
            let topaz2K = Self.spec(.upscale(UpscaleOptions(target: .k2, engine: .topaz)))

            for spec in [unsized, topaz2K] {
                await #expect(throws: HiggsfieldMCPProvider.notAvailable) { try await provider.estimate(spec) }
            }
            #expect(Provider.calls(stub).isEmpty)
        }

        @Test func aKeptFrameRateOfAStoredJobIsLeftOut() async throws {
            let (provider, stub) = Self.provider { _, _ in ["results": [["id": "job-3"]]] }
            let spec = Self.spec(.upscale(UpscaleOptions(target: .p1080, frameRate: .keep)))

            _ = try await provider.submit(spec, inputs: Self.noInputs, idempotencyKey: UUID())

            #expect(Self.params(stub).first??["fps"] == nil)
        }

        @Test func removeBackgroundIsQuotedAndRunsOnTheUpload() async throws {
            let (provider, stub) = Self.provider { name, _ in
                name == "generate_video" ? ["cost": ["credits": 1]] : ["results": [["id": "job-4"]]]
            }
            let spec = Self.spec(.removeBackground)

            #expect(try await provider.estimate(spec) == .credits(1, isEstimate: true))
            let remote = try await provider.submit(spec, inputs: Self.uploaded, idempotencyKey: UUID())

            #expect(remote.requestID == "job-4")
            #expect(
                Self.params(stub) == [
                    ["model": "video_background_remover", "get_cost": true, "duration": 10],
                    ["media_id": "5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50", "media_type": "video"],
                ])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func reframeIsQuotedBeforeUploadEvenForAnUploadedResult() async throws {
            let (provider, stub) = Self.provider { _, arguments in
                arguments["params"]?["get_cost"] == true ? ["cost": ["credits": 41]] : ["results": [["id": "job-5"]]]
            }
            let spec = Self.spec(.reframe(.square), jobID: nil, seconds: 20)

            #expect(try await provider.estimate(spec) == .credits(41, isEstimate: true))
            #expect(try await provider.serverEstimate(spec, inputs: Self.uploaded) == .credits(41, isEstimate: false))
            _ = try await provider.submit(spec, inputs: Self.uploaded, idempotencyKey: UUID())

            let quote: JSONValue = ["get_cost": true, "duration_seconds": 20, "resolution": "720p"]
            #expect(
                Self.params(stub) == [
                    quote, quote,
                    [
                        "medias": [["role": "video", "value": "5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50"]],
                        "aspect_ratio": "1:1",
                        "duration_seconds": 20, "resolution": "720p",
                    ],
                ])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func aResultOverAMinuteCantBeReframed() async throws {
            let (provider, stub) = Self.provider()
            await #expect(throws: HiggsfieldMCPProvider.notAvailable) {
                try await provider.estimate(Self.spec(.reframe(.portrait), seconds: 61))
            }
            #expect(Provider.calls(stub).isEmpty)
        }

        /// A 7 s dub is 21 credits, as Higgsfield billed one on 2026-10-15; a price question that fails leaves the
        /// price unknown.
        @Test func dubAndChangeVoiceAreQuotedByLengthAndNameTheResult() async throws {
            let (provider, stub) = Self.provider { name, arguments in
                guard name == "generate_video" else { return ["results": [["id": "job-6"]]] }
                return arguments["params"]?["model"] == "dubbing" ? ["cost": ["credits": 21]] : ["error": "failed"]
            }
            let dub = Self.spec(.dub(.japanese), seconds: 7.04)
            let voice = Self.spec(.changeVoice(Self.voice))

            #expect(try await provider.estimate(dub) == .credits(21, isEstimate: true))
            #expect(try await provider.estimate(voice) == .unknownCredits)
            _ = try await provider.submit(dub, inputs: Self.noInputs, idempotencyKey: UUID())
            _ = try await provider.submit(voice, inputs: Self.uploaded, idempotencyKey: UUID())

            #expect(
                Provider.calls(stub).map { $0["name"] } == [
                    "generate_video", "generate_video", "dubbing", "voice_change",
                ])
            #expect(
                Self.params(stub) == [
                    ["model": "dubbing", "get_cost": true, "duration": 7],
                    ["model": "voice_change", "get_cost": true, "duration": 10],
                    ["video_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "target_language": "jpn"],
                    ["video_id": "5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50", "voice_id": "v-1", "voice_type": "element"],
                ])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func voicesAreReadOncePerConnection() async throws {
            let (provider, stub) = Self.provider { name, arguments in
                guard name == "list_voices" else { return [:] }
                return arguments["cursor"] == nil
                    ? [
                        "voices": [
                            [
                                "voice_id": "v-1", "voice_type": "preset", "name": "Amber",
                                "preview_url": "https://cdn.example/amber.mp3",
                            ]
                        ],
                        "has_more": true, "next_cursor": "c-2",
                    ]
                    : ["voices": [["voice_id": "v-2", "voice_type": "element", "name": "Mine"]], "has_more": false]
            }

            let voices = try await provider.voices()
            let again = try await provider.voices()

            #expect(
                voices == [
                    AccountVoice(
                        choice: VoiceChoice(id: "v-1", type: "preset", name: "Amber"),
                        previewURL: URL(string: "https://cdn.example/amber.mp3")),
                    AccountVoice(choice: VoiceChoice(id: "v-2", type: "element", name: "Mine")),
                ])
            #expect(again == voices)
            #expect(Provider.calls(stub).count == 2)
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func aMissingToolIsNotAvailable() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet)

            await #expect(throws: ProviderError.self) { try await provider.estimate(Self.spec(Self.upscale)) }
            await #expect(throws: ProviderError.self) { try await provider.estimate(Self.spec(.dub(.french))) }
            #expect(Provider.calls(stub).isEmpty)
        }

        @Test func anOperationIsNeverPaidFromTheUnlimitedAllowance() async throws {
            let (provider, _) = Self.provider()
            #expect(await provider.paysUnlimited(Self.spec(Self.upscale)) == false)
        }

        @Test func aLostAnswerMayHaveStartedTheOperation() async throws {
            let (provider, _) = Self.provider { _, _ in ["ok": true] }
            await #expect(throws: ProviderError.outcomeUnknown) {
                try await provider.submit(Self.spec(Self.upscale), inputs: Self.noInputs, idempotencyKey: UUID())
            }
        }
    }
}

/// The REST API has none of the operations.
@Suite struct APIPostOperations {
    @Test func anAPIKeyRefusesOperations() async throws {
        var spec = JobSpec(
            mode: .motionTransfer,
            source: SourceClip(
                fileURL: URL(fileURLWithPath: "/tmp/in.mov"), duration: 4,
                pixelSize: PixelSize(width: 640, height: 360),
                range: 0...4), resolution: .p720)
        spec.operation = PostOperation(action: .removeBackground)
        #expect(throws: APIModel.needsAccount) { try APIModel(spec, inputs: RemoteInputs(video: nil, images: [])) }
    }
}
