import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import JutsuTestSupport
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Tools and answers as the live server gave them on 2026-10-14, trimmed to the keys the provider reads.
    @Suite struct Provider {
        static let generate = tool("generate_video", "Generate one direct video request", ["params", "context"])
        static let upload = tool("media_upload", "Upload media for use in generation", ["filename", "content_type"])
        static let confirm = tool("media_confirm", "Confirm file uploads", ["media_id", "type"])
        static let status = tool("job_status", "Check the status and results of an async job", ["jobId", "sync"])
        static let balance = tool("balance", "Get the user's available credits and current plan", [])
        static let unrelated = tool("generate_image", "Text to image with motion blur", ["params"])
        static let fullSet = [unrelated, generate, upload, confirm, status, balance]

        static func provider(
            tools: [JSONValue], call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        )
            -> (HiggsfieldMCPProvider, StubServer)
        {
            let stub = mcpServer(tools: tools, call: call)
            let session = stub.session()
            return (makeProvider(session), stub)
        }

        static func spec(_ mode: Mode) -> JobSpec {
            let source = SourceClip(
                fileURL: URL(fileURLWithPath: "/tmp/in.mov"), duration: 10,
                pixelSize: PixelSize(width: 1280, height: 720),
                range: 0...10)
            return JobSpec(mode: mode, source: source, resolution: .p720)
        }

        static let inputs = RemoteInputs(
            video: RemoteAsset(url: URL(fileURLWithPath: "/in.mp4"), id: "video-1"),
            images: [RemoteAsset(url: URL(fileURLWithPath: "/a.jpg"), id: "image-1")])
        static let image = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))

        static func calls(_ stub: StubServer) -> [JSONValue] {
            stub.requests.filter { $0.json?["method"] == "tools/call" }.compactMap { $0.json?["params"] }
        }

        /// Where the calls the stub got break their tool's `inputSchema` in the catalog snapshot; empty when none do.
        static func schemaViolations(_ stub: StubServer) throws -> [String] {
            try calls(stub).flatMap { call in
                try CatalogSnapshot.violations(of: call["arguments"] ?? [:], sentTo: call["name"]?.stringValue ?? "")
            }
        }

        @Test func fullToolSetEnablesMotionAndSwapInCredits() async throws {
            let (provider, _) = Self.provider(tools: Self.fullSet)
            let capabilities = try await provider.capabilities()
            #expect(capabilities.modes == [.motionTransfer, .objectSwap, .edit, .extend])
            #expect(
                capabilities.models.map(\.rawValue).sorted() == [
                    "cinemaStudio4", "genjutsu", "genjutsuLite", "klingMotionControl", "klingO3VideoEdit",
                    "minimaxH3MaxReference", "minimaxH3Reference", "seedance25", "wan30PrimeReference",
                    "wan30Reference",
                ])
            #expect(capabilities.parameters == [.seedanceBitrate, .seedanceFrames, .klingVideoBackground])
            #expect(capabilities.costUnit == .credits)
            #expect(provider.kind == .account)
        }

        @Test func anyMissingJobToolDisablesEveryMode() async throws {
            let (provider, _) = Self.provider(tools: [Self.generate, Self.upload, Self.status])
            #expect(try await provider.capabilities().modes.isEmpty)
            await #expect(throws: HiggsfieldMCPProvider.notAvailable) { try await provider.presets() }
            #expect(try await provider.balance() == nil)
        }

        @Test func schemaMismatchDisablesTheTool() async throws {
            let statusByRequestID = tool("job_status", "Status", ["request_id"])
            let (provider, _) = Self.provider(tools: [Self.generate, Self.upload, Self.confirm, statusByRequestID])
            #expect(try await provider.capabilities().modes.isEmpty)
        }

        @Test func restyleWithoutAStyleIsNotSent() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet)
            await #expect(throws: HiggsfieldMCPProvider.notAvailable) {
                try await provider.submit(Self.spec(.restyle), inputs: Self.inputs, idempotencyKey: UUID())
            }
            #expect(Self.calls(stub).isEmpty)
        }

        @Test func submitSendsTheModelAndMediaIDsAndReadsTheJob() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { name, _ in
                switch name {
                case "generate_video":
                    ["results": [["id": "job-1", "status": "queued"]], "request_id": "trace-1"]
                case "job_status":
                    [
                        "generation": [
                            "id": "job-1", "status": "completed", "results": ["rawUrl": "https://cdn.example/out.mp4"],
                        ]
                    ]
                case "balance": ["credits": .number(2596.34), "subscription_plan_type": "ultra"]
                default: [:]
                }
            }
            var spec = Self.spec(.motionTransfer)
            spec.prompt = "keep the background"
            let job = try await provider.submit(spec, inputs: Self.inputs, idempotencyKey: UUID())
            #expect(job.requestID == "job-1")
            #expect(job.correlationID == "trace-1")
            let output = try #require(URL(string: "https://cdn.example/out.mp4"))
            #expect(try await provider.status(job) == .completed(videoURL: output))
            #expect(try await provider.balance() == .credits(2596, plan: "ultra"))  // 2596.34, rounded down

            let calls = Self.calls(stub)
            #expect(calls.map { $0["name"] } == ["generate_video", "job_status", "balance"])
            #expect(
                calls.first?["arguments"] == [
                    "params": [
                        "model": "hf_mult_motion_control",
                        "medias": [
                            ["role": "video_references", "value": "video-1"],
                            ["role": "image_references", "value": "image-1"],
                        ],
                        "resolution": "720p", "use_unlim": false, "prompt": "keep the background",
                    ]
                ])
            #expect(calls[1]["arguments"] == ["jobId": "job-1"])
        }

        @Test func swapUsesTheReplaceObjectModel() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { _, _ in ["results": [["id": "job-2"]]] }
            _ = try await provider.submit(Self.spec(.objectSwap), inputs: Self.inputs, idempotencyKey: UUID())
            #expect(Self.calls(stub).first?["arguments"]?["params"]?["model"] == "hf_mult_replace_object")
        }

        @Test func otherModelsSendTheirOwnParams() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { _, _ in ["results": [["id": "job-3"]]] }
            var seedance = Self.spec(.motionTransfer)
            seedance.model = .seedance25
            var kling = Self.spec(.motionTransfer)
            kling.model = .klingMotionControl
            kling.resolution = .p1080
            _ = try await provider.submit(seedance, inputs: Self.inputs, idempotencyKey: UUID())
            _ = try await provider.submit(kling, inputs: Self.inputs, idempotencyKey: UUID())

            let params = Self.calls(stub).compactMap { $0["arguments"]?["params"]?.objectValue }
            #expect(params[0]["model"] == "seedance_2_5")
            #expect(params[0]["mode"] == "omni_reference")
            #expect(params[0]["duration"] == 10)
            #expect(params[0]["resolution"] == "720p")
            #expect(params[0]["generate_audio"] == false)
            #expect(params[1]["model"] == "kling3_0_motion_control")
            #expect(params[1]["mode"] == "pro")
            #expect(params[1]["duration"] == 10)
            #expect(params[1]["resolution"] == nil)
        }

        @Test func seedanceMakesAClipFromThePromptAloneOrWithImages() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { _, _ in ["results": [["id": "job-4"]]] }
            var prompted = JobSpec(
                mode: .motionTransfer, model: .seedance25, source: nil, prompt: "a fox in the snow", resolution: .p480,
                length: 12, aspectRatio: .portrait)
            _ = try await provider.submit(
                prompted, inputs: RemoteInputs(video: nil, images: []), idempotencyKey: UUID())
            prompted.audio = .mute
            prompted.aspectRatio = nil
            let withImage = RemoteInputs(video: nil, images: Self.inputs.images)
            _ = try await provider.submit(prompted, inputs: withImage, idempotencyKey: UUID())

            let params = Self.calls(stub).compactMap { $0["arguments"]?["params"]?.objectValue }
            #expect(params[0]["mode"] == "t2v")
            #expect(params[0]["medias"] == nil)
            #expect(params[0]["duration"] == 12)
            #expect(params[0]["aspect_ratio"] == "9:16")
            #expect(params[0]["generate_audio"] == true)
            #expect(params[0]["prompt"] == "a fox in the snow")
            #expect(params[1]["mode"] == "omni_reference")
            #expect(params[1]["medias"] == [["role": "image_references", "value": "image-1"]])
            #expect(params[1]["aspect_ratio"] == "auto")
            #expect(params[1]["generate_audio"] == false)
            #expect(try await provider.estimate(prompted) == .credits(36, isEstimate: true))
        }

        @Test func otherModelsServeMotionOnly() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet)
            var swap = Self.spec(.objectSwap)
            swap.model = .seedance25
            await #expect(throws: HiggsfieldMCPProvider.notAvailable) {
                try await provider.submit(swap, inputs: Self.inputs, idempotencyKey: UUID())
            }
            await #expect(throws: HiggsfieldMCPProvider.notAvailable) { try await provider.estimate(swap) }
            #expect(Self.calls(stub).isEmpty)
        }

        /// Edit and Extend as `models_explore get` of `seedance_2_5` names them (catalog snapshot of 2026-10-15), with
        /// the clip as `video_references`: Edit's output follows the clip, so it sends no length; Extend sends the
        /// seconds it adds and `extension_mode: "forward"`, and makes the new part's sound.
        @Test func editAndExtendSendTheConfirmedModes() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { _, _ in ["results": [["id": "job-7"]]] }
            var edit = Self.spec(.edit)
            edit.model = .seedance25
            edit.prompt = "make it night"
            var extend = edit
            extend.mode = .extend
            extend.length = 6
            let clip = RemoteInputs(video: Self.inputs.video, images: [])

            let modes = try await provider.capabilities().modes
            #expect(modes.contains(.edit) && modes.contains(.extend))
            _ = try await provider.submit(edit, inputs: clip, idempotencyKey: UUID())
            _ = try await provider.submit(extend, inputs: clip, idempotencyKey: UUID())

            let params = Self.calls(stub).filter { $0["name"] == "generate_video" }.compactMap {
                $0["arguments"]?["params"]
            }
            let video: JSONValue = [["role": "video_references", "value": "video-1"]]
            #expect(
                params == [
                    [
                        "model": "seedance_2_5", "mode": "video_edit", "medias": video, "prompt": "make it night",
                        "resolution": "720p", "generate_audio": false, "use_unlim": false,
                    ],
                    [
                        "model": "seedance_2_5", "mode": "video_extension", "extension_mode": "forward",
                        "medias": video, "prompt": "make it night", "resolution": "720p", "duration": 6,
                        "generate_audio": true, "use_unlim": false,
                    ],
                ])
        }

        /// `generate_audio` is a confirmed key: with a source, Seedance makes the sound when the job asks for it.
        @Test func seedanceWithASourceMakesItsOwnSoundWhenAsked() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { _, _ in ["results": [["id": "job-5"]]] }
            var seedance = Self.spec(.motionTransfer)
            seedance.model = .seedance25
            seedance.audio = .generated
            _ = try await provider.submit(seedance, inputs: Self.inputs, idempotencyKey: UUID())

            let params = Self.calls(stub).compactMap { $0["arguments"]?["params"]?.objectValue }
            #expect(params.first?["mode"] == "omni_reference")
            #expect(params.first?["generate_audio"] == true)
        }

        /// Seedance's frames and bitrate as `models_explore get` of `seedance_2_5` names them: the images as
        /// `start_image` and `end_image` under `omni_reference` with the start frame's shape as `aspect_ratio` (left
        /// out, a 9:16 start frame made a 16:9 clip live on 2026-10-15), and `bitrate_mode` only when picked (left
        /// out, the account's default is `standard`).
        @Test func seedanceSendsFramesAndThePickedBitrate() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { _, _ in ["results": [["id": "job-6"]]] }
            var frames = JobSpec(
                mode: .motionTransfer, model: .seedance25, source: nil, references: [Self.image, Self.image],
                resolution: .p720, length: 5, aspectRatio: .portrait, bitrate: .high, referencesAreFrames: true)
            let images = RemoteInputs(
                video: nil,
                images: [
                    RemoteAsset(url: URL(fileURLWithPath: "/a.jpg"), id: "image-1"),
                    RemoteAsset(url: URL(fileURLWithPath: "/b.jpg"), id: "image-2"),
                ])

            #expect(try await provider.capabilities().parameters.contains(.seedanceFrames))
            #expect(try await provider.estimate(frames) == .credits(35, isEstimate: true))
            _ = try await provider.submit(frames, inputs: images, idempotencyKey: UUID())
            frames.referencesAreFrames = false
            frames.bitrate = nil
            _ = try await provider.submit(frames, inputs: images, idempotencyKey: UUID())

            // The submits; the estimate's quote is the call with `get_cost`.
            let params = Self.calls(stub).filter { $0["name"] == "generate_video" }.compactMap {
                $0["arguments"]?["params"]
            }.filter { $0["get_cost"] == nil }
            #expect(params.count == 2)
            #expect(
                params.first == [
                    "model": "seedance_2_5", "mode": "omni_reference",
                    "medias": [
                        ["role": "start_image", "value": "image-1"], ["role": "end_image", "value": "image-2"],
                    ],
                    "resolution": "720p", "duration": 5, "generate_audio": true, "bitrate_mode": "high",
                    "aspect_ratio": "9:16", "use_unlim": false,
                ])
            #expect(params.last?["mode"] == "omni_reference" && params.last?["bitrate_mode"] == nil)
            #expect(params.last?["aspect_ratio"] == "9:16")
        }

        /// `models_explore get` of `kling3_0_motion_control` lists only `mode` and `background_source`: the account
        /// offers neither the source's sound on the server nor the character's orientation, and sends neither.
        @Test func klingSendsNoSoundOrOrientation() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { _, _ in ["results": [["id": "job-8"]]] }
            let parameters = try await provider.capabilities().parameters
            #expect(!parameters.contains(.klingOriginalSound) && !parameters.contains(.klingOrientation))
            var kling = Self.spec(.motionTransfer)
            kling.model = .klingMotionControl
            kling.audio = .original
            kling.characterOrientation = .image
            _ = try await provider.submit(kling, inputs: Self.inputs, idempotencyKey: UUID())

            #expect(
                Self.calls(stub).first { $0["name"] == "generate_video" }?["arguments"]?["params"] == [
                    "model": "kling3_0_motion_control", "mode": "std", "duration": 10,
                    "medias": [
                        ["role": "video_references", "value": "video-1"],
                        ["role": "image_references", "value": "image-1"],
                    ],
                    "use_unlim": false,
                ])
        }

        /// Explicit quotes also protect rounding and duration clamping.
        @Test(arguments: [
            (VideoModel.genjutsu, Resolution.p1080, 10.0, 200), (.seedance25, .p480, 10, 30),
            (.seedance25, .p1080, 10, 160), (.klingMotionControl, .p720, 10, 18),
            (.klingMotionControl, .p1080, 10, 28), (.seedance25, .p480, 5.5, 18),
            (.seedance25, .p480, 41, 90), (.klingMotionControl, .p1080, 5.5, 18),
        ])
        func estimateFollowsTheModel(
            model: VideoModel, resolution: Resolution, seconds: Double, credits: Int
        ) async throws {
            let (provider, _) = Self.provider(tools: Self.fullSet)
            var spec = Self.spec(.motionTransfer)
            spec.model = model
            spec.resolution = resolution
            spec.source?.range = 0...seconds
            #expect(try await provider.estimate(spec) == .credits(Decimal(credits), isEstimate: true))
        }

        @Test func declinedSubmitCarriesTheServerReason() async throws {
            let (provider, _) = Self.provider(tools: Self.fullSet) { _, _ in ["error": "Not enough credits"] }
            await #expect(throws: ProviderError.validation(field: nil, message: "Not enough credits")) {
                try await provider.submit(Self.spec(.motionTransfer), inputs: Self.inputs, idempotencyKey: UUID())
            }
        }

        @Test func assetWithoutMediaIDIsRefused() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet)
            let inputs = RemoteInputs(video: RemoteAsset(url: URL(fileURLWithPath: "/in.mp4")), images: [])
            await #expect(throws: ProviderError.self) {
                try await provider.submit(Self.spec(.motionTransfer), inputs: inputs, idempotencyKey: UUID())
            }
            #expect(Self.calls(stub).isEmpty)
        }

        @Test(arguments: [
            (JSONValue.object(["status": "queued"]), RemoteStatus.queued),
            (.object(["status": "in_progress"]), .inProgress),
            (.object(["status": "failed", "error": "Bad input"]), .failed(message: "Bad input")),
            (.object(["status": "nsfw"]), .rejected(.explicitContent)),
            (.object(["status": "ip_detected"]), .rejected(.protectedContent)),
            (.object(["status": "canceled"]), .canceled),
        ])
        func statusMapsToRemoteStatus(generation: JSONValue, expected: RemoteStatus) async throws {
            let (provider, _) = Self.provider(tools: Self.fullSet) { _, _ in ["generation": generation] }
            #expect(try await provider.status(RemoteJob(requestID: "job-1")) == expected)
        }

        @Test func estimateIsPerSecondAndTheServerQuoteIsExact() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet) { _, _ in
                ["cost": ["credits": 55, "credits_exact": .number(55.5)]]
            }
            let spec = Self.spec(.objectSwap)
            #expect(try await provider.estimate(spec) == .credits(76, isEstimate: true))
            #expect(try await provider.serverEstimate(spec, inputs: Self.inputs) == .credits(55.5, isEstimate: false))
            #expect(Self.calls(stub).first?["arguments"]?["params"]?["get_cost"] == true)
        }

        @Test func uploadPutsTheFileAndConfirmsItsMediaID() async throws {
            let mcp = mcpServer(tools: Self.fullSet) { name, _ in
                name == "media_upload"
                    ? [
                        "uploads": [
                            [
                                "media_id": "media-1", "method": "PUT",
                                "upload_url": "https://upload.example/in.mp4?X-Signature=abc",
                                "url": "https://cdn.example/media-1.mp4",
                            ]
                        ]
                    ]
                    : ["results": [["media_id": "media-1", "status": "uploaded"]]]
            }
            let stub = StubServer { request, _ in request.method == "PUT" ? StubResponse() : mcp.respond(to: request) }
            let session = stub.session()
            let provider = makeProvider(session)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try Data("0123456789".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let asset = try await provider.upload(
                PreparedFile(fileURL: file, contentType: "video/mp4", byteCount: 10, contentHash: "h"))

            let publicURL = try #require(URL(string: "https://cdn.example/media-1.mp4"))
            #expect(asset == RemoteAsset(url: publicURL, id: "media-1"))
            let put = try #require(stub.requests.first { $0.method == "PUT" })
            #expect(put.url.absoluteString == "https://upload.example/in.mp4?X-Signature=abc")
            #expect(put.header("Content-Type") == "video/mp4")
            #expect(put.header("Authorization") == nil)
            let calls = Self.calls(stub)
            #expect(
                calls.first?["arguments"] == ["filename": .string(file.lastPathComponent), "content_type": "video/mp4"])
            #expect(calls.last?["arguments"] == ["media_id": "media-1", "type": "video"])
        }

        @Test func cancelIsRefused() async throws {
            let (provider, _) = Self.provider(tools: Self.fullSet)
            await #expect(throws: HiggsfieldMCPProvider.notCancellable) {
                try await provider.cancel(RemoteJob(requestID: "job-1"))
            }
        }

        /// The MCP stub, except that every `generate_video` call answers `status`.
        static func failingSubmit(status: Int) -> (HiggsfieldMCPProvider, StubServer) {
            let mcp = mcpServer(tools: fullSet)
            let stub = StubServer { request, _ in
                request.json?["params"]?["name"] == "generate_video"
                    ? StubResponse(status: status) : mcp.respond(to: request)
            }
            let session = stub.session()
            return (makeProvider(session), stub)
        }

        @Test func ambiguousSubmitFailureIsNotRetryable() async throws {
            let (provider, stub) = Self.failingSubmit(status: 502)
            await #expect(throws: ProviderError.outcomeUnknown) {
                try await provider.submit(Self.spec(.motionTransfer), inputs: Self.inputs, idempotencyKey: UUID())
            }
            #expect(Self.calls(stub).count == 1)
            #expect(try await !provider.submitIsIdempotent(Self.spec(.motionTransfer)))
            #expect(provider.owner == "user_1")
        }

        @Test(arguments: [
            (-32603 as Int?, ProviderError.outcomeUnknown), (-32000, .outcomeUnknown), (nil, .outcomeUnknown),
            (-32602, .validation(field: nil, message: "Internal failure")),
        ])
        func toolFailuresPreserveWhetherASubmitCanBeRetried(code: Int?, expected: ProviderError) async throws {
            let answering = mcpServer(tools: Self.fullSet)
            let stub = StubServer { request, _ in
                guard request.json?["params"]?["name"] == "generate_video", let id = request.json?["id"] else {
                    return answering.respond(to: request)
                }
                let payload: JSONValue =
                    code.map {
                        ["error": ["code": .number(Double($0)), "message": "Internal failure"]]
                    } ?? ["result": ["isError": true, "content": [["type": "text", "text": "Internal failure"]]]]
                return .json(
                    .object((payload.objectValue ?? [:]).merging(["jsonrpc": "2.0", "id": id]) { _, new in new }))
            }
            let provider = makeProvider(stub.session())
            await #expect(throws: expected) {
                try await provider.submit(Self.spec(.motionTransfer), inputs: Self.inputs, idempotencyKey: UUID())
            }
            #expect(Self.calls(stub).count == 1)
        }

        /// Higgsfield's refusal before execution, as the live server words it, keeps its reason.
        @Test func anInvalidRequestRefusalIsAValidationError() async throws {
            let message = "Invalid request: unknown model \"x\"."
            let answering = mcpServer(tools: Self.fullSet)
            let stub = StubServer { request, _ in
                guard request.json?["params"]?["name"] == "generate_video", let id = request.json?["id"] else {
                    return answering.respond(to: request)
                }
                return .json([
                    "jsonrpc": "2.0", "id": id,
                    "result": ["isError": true, "content": [["type": "text", "text": .string(message)]]],
                ])
            }
            let provider = makeProvider(stub.session())
            await #expect(throws: ProviderError.validation(field: nil, message: message)) {
                try await provider.submit(Self.spec(.motionTransfer), inputs: Self.inputs, idempotencyKey: UUID())
            }
        }

        /// The MCP stub, except that every call to `name` answers with `payload` merged into the JSON-RPC reply.
        static func answering(
            _ name: String, with payload: JSONValue, tools: [JSONValue] = fullSet,
            call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        ) -> StubServer {
            let answering = mcpServer(tools: tools, call: call)
            return StubServer { request, _ in
                guard request.json?["params"]?["name"]?.stringValue == name, let id = request.json?["id"] else {
                    return answering.respond(to: request)
                }
                return .json(
                    .object((payload.objectValue ?? [:]).merging(["jsonrpc": "2.0", "id": id]) { _, new in new }))
            }
        }

        /// A poll of a job that may already be paid is retried when its answer can't be read, never ended.
        @Test(arguments: [
            JSONValue.object(["result": ["isError": true, "content": [["type": "text", "text": "Busy"]]]]),
            ["error": ["code": -32602, "message": "Invalid params"]],
            ["result": ["content": [["type": "text", "text": "done"]], "structuredContent": [:]]],
        ])
        func anUnreadableStatusIsARetryableServerError(payload: JSONValue) async throws {
            let provider = makeProvider(Self.answering("job_status", with: payload).session())
            await #expect(throws: ProviderError.server(status: 200)) {
                try await provider.status(RemoteJob(requestID: "job-1"))
            }
        }

        /// A paid call that fails before it is sent can be retried: nothing reached the server.
        @Test func aSubmitThatFailsBeforeSendingIsANetworkError() async throws {
            let stub = StubServer { request, _ in
                request.json?["method"] == "initialize" ? StubResponse(status: 503) : .notFound
            }
            let provider = makeProvider(stub.session())
            await #expect(throws: ProviderError.network) {
                try await provider.submit(Self.spec(.motionTransfer), inputs: Self.inputs, idempotencyKey: UUID())
            }
            #expect(Self.calls(stub).isEmpty)
        }

        @Test(arguments: [(-1.0, 1), (1e30, 1), (Double(Int.max), 1), (Double(Int.max) / 2, 4)])
        func malformedServerPricesAreErrors(credits: Double, variants: Int) async throws {
            let (provider, _) = Self.provider(tools: Self.fullSet) { _, _ in
                ["cost": ["credits_exact": .number(credits)]]
            }
            var spec = Self.spec(.motionTransfer)
            spec.variants = variants
            await #expect(throws: ProviderError.server(status: 200)) {
                try await provider.serverEstimate(spec, inputs: Self.inputs)
            }
        }

        @Test func refusedSubmitStaysAsIs() async throws {
            let (provider, _) = Self.failingSubmit(status: 429)
            await #expect(throws: ProviderError.server(status: 429)) {
                try await provider.submit(Self.spec(.motionTransfer), inputs: Self.inputs, idempotencyKey: UUID())
            }
        }

        @Test func submitCancelledBeforeTheCallSendsNothing() async throws {
            let (provider, stub) = Self.provider(tools: Self.fullSet)
            let submit = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await provider.submit(
                    Self.spec(.motionTransfer), inputs: Self.inputs, idempotencyKey: UUID())
            }
            await #expect(throws: CancellationError.self) { try await submit.value }
            #expect(stub.requests.isEmpty)
        }

        // Darwin only: the stub blocks the loading thread, and Linux Foundation may not end a cancelled task
        // until the load returns.
        #if !canImport(FoundationNetworking)
            @Test func submitCancelledDuringTheCallHasAnUnknownOutcome() async throws {
                let release = DispatchSemaphore(value: 0)
                let (provider, stub) = Self.provider(tools: Self.fullSet) { name, _ in
                    if name == "generate_video" { _ = release.wait(timeout: .now() + 10) }
                    return ["results": [["id": "job-1"]]]
                }
                defer { release.signal() }
                let submit = Task {
                    try await provider.submit(Self.spec(.motionTransfer), inputs: Self.inputs, idempotencyKey: UUID())
                }
                await eventually { Self.calls(stub).count == 1 }

                submit.cancel()
                await #expect(throws: ProviderError.outcomeUnknown) { try await submit.value }
            }
        #endif

        @Test(arguments: [
            (HiggsfieldError.network, true), (.server(status: 500), true), (.server(status: 200), true),
            (.server(status: 404), false), (.unauthorized, false), (.validation(field: nil, message: "x"), false),
        ])
        func ambiguousFailures(error: HiggsfieldError, mayHaveReachedServer: Bool) {
            #expect(HiggsfieldMCPProvider.mayHaveReachedServer(error) == mayHaveReachedServer)
        }
    }
}
