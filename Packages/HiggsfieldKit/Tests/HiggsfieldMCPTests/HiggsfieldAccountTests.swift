import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

extension Network {
    /// The tool contract as the live server gave it on 2026-10-14, trimmed to the keys the client reads.
    @Suite struct Account {
        static let fullSet = [
            tool("generate_image", "Text to image", ["params"]),
            tool("generate_video", "Generate one direct video request", ["params", "context"]),
            tool("media_upload", "Upload media for use in generation", ["filename", "content_type"]),
            tool("media_confirm", "Confirm file uploads", ["media_id", "type"]),
            tool("job_status", "Check the status and results of an async job", ["jobId", "sync"]),
            tool("balance", "Get the user's available credits and current plan", []),
        ]

        static let request = VideoRequest(
            model: .klingMotionControl,
            media: [.init(role: .video, id: "video-1"), .init(role: .image, id: "image-1")], prompt: "slow",
            mode: VideoRequest.klingPro, duration: 10)

        static func account(
            tools: [JSONValue] = fullSet, call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        ) -> (HiggsfieldAccount, StubServer) {
            account(tools: Locked(tools), call: call)
        }

        /// A server whose tool list the test changes through `tools`, and an account that reads the time from `now`.
        static func account(
            tools: Locked<[JSONValue]>, now: Locked<Date> = Locked(Date()),
            call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        ) -> (HiggsfieldAccount, StubServer) {
            let stub = mcpServer(tools: { tools.value }, call: call)
            let session = stub.session()
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: session)
            return (HiggsfieldAccount(client: client, session: session, now: { now.value }), stub)
        }

        static func calls(_ stub: StubServer) -> [JSONValue] {
            stub.requests.filter { $0.json?["method"] == "tools/call" }.compactMap { $0.json?["params"] }
        }

        /// Where the calls the stub got break their tool's `inputSchema` in the catalog snapshot; empty when none do.
        static func schemaViolations(_ stub: StubServer) throws -> [String] {
            try calls(stub).flatMap { call in
                try CatalogSnapshot.violations(of: call["arguments"] ?? [:], sentTo: call["name"]?.stringValue ?? "")
            }
        }

        static func listings(_ stub: StubServer) -> Int {
            stub.requests.filter { $0.json?["method"] == "tools/list" }.count
        }

        static let withoutGenerate = fullSet.filter { $0["name"] != "generate_video" }

        @Test func generateSendsTheParamsAndReadsTheJob() async throws {
            let (account, stub) = Self.account { _, _ in ["results": [["id": "job-1"]], "request_id": "trace-1"] }

            #expect(try await account.refreshTools())
            let generation = try await account.generate(Self.request)

            #expect(generation == Generation(id: "job-1", requestID: "trace-1"))
            #expect(
                Self.calls(stub).first
                    == [
                        "name": "generate_video",
                        "arguments": [
                            "params": [
                                "model": "kling3_0_motion_control",
                                "medias": [
                                    ["role": "video_references", "value": "video-1"],
                                    ["role": "image_references", "value": "image-1"],
                                ],
                                "mode": "pro", "duration": 10, "prompt": "slow", "use_unlim": false,
                            ]
                        ],
                    ])
        }

        @Test func anUnreadableGenerateReplyIsNotARefusal() async throws {
            let (unreadable, _) = Self.account { _, _ in ["results": []] }
            await #expect(throws: HiggsfieldError.server(status: 200)) { try await unreadable.generate(Self.request) }

            let (declined, _) = Self.account { _, _ in ["error": "Prompt is too long"] }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Prompt is too long")) {
                try await declined.generate(Self.request)
            }
        }

        /// As the server answered a long Genjutsu prompt on 2026-10-14, trimmed.
        static let presetNotice: JSONValue = [
            "notice": [
                "type": "preset_recommendation",
                "message": "This prompt looks like the Higgsfield preset \"IN THE DARK\".",
                "data": ["retry_literal_with": ["declined_preset_id": "preset-1"]],
            ]
        ]

        @Test func aSuggestedPresetIsDeclinedOnce() async throws {
            let (account, stub) = Self.account { _, arguments in
                arguments["params"]?["declined_preset_id"] == nil ? Self.presetNotice : ["results": [["id": "job-1"]]]
            }
            #expect(try await account.generate(Self.request).id == "job-1")
            let sent = Self.calls(stub).map { $0["arguments"]?["params"]?["declined_preset_id"] }
            #expect(sent == [nil, "preset-1"])
        }

        @Test func aQuoteDeclinesTheSuggestedPresetToo() async throws {
            let (account, _) = Self.account { _, arguments in
                arguments["params"]?["declined_preset_id"] == nil ? Self.presetNotice : ["cost": ["credits_exact": 45]]
            }
            #expect(try await account.cost(of: Self.request) == 45)
        }

        @Test func aNoticeDoesNotResubmitAnAcceptedGeneration() async throws {
            let (account, stub) = Self.account { _, _ in
                var answer = Self.presetNotice.objectValue ?? [:]
                answer["results"] = [["id": "paid-job"]]
                return .object(answer)
            }
            #expect(try await account.generate(Self.request).id == "paid-job")
            #expect(Self.calls(stub).count == 1)
        }

        @Test func aNoticeAloneSubmittedNothing() async throws {
            let (account, stub) = Self.account { _, _ in Self.presetNotice }
            await #expect(
                throws: HiggsfieldError.validation(
                    field: nil, message: "This prompt looks like the Higgsfield preset \"IN THE DARK\".")
            ) { try await account.generate(Self.request) }
            #expect(Self.calls(stub).count == 2)
        }

        @Test func costAsksForAQuote() async throws {
            let (account, stub) = Self.account { _, _ in ["cost": ["credits": 28, "credits_exact": .number(27.5)]] }
            #expect(try await account.cost(of: Self.request) == 27.5)
            #expect(Self.calls(stub).first?["arguments"]?["params"]?["get_cost"] == true)
        }

        @Test func missingToolsAreReportedByName() async throws {
            let (account, stub) = Self.account(tools: [tool("job_status", "Status", ["request_id"])])
            #expect(try await !account.refreshTools())
            await #expect(throws: HiggsfieldError.toolUnavailable("generate_video")) {
                try await account.generate(Self.request)
            }
            await #expect(throws: HiggsfieldError.toolUnavailable("job_status")) {
                try await account.status(of: "job-1")
            }
            #expect(try await account.balance() == nil)
            #expect(Self.calls(stub).isEmpty)
        }

        @Test(arguments: [
            (JSONValue.object(["status": "pending"]), GenerationStatus.queued),
            (.object(["status": "processing"]), .inProgress),
            (.object(["status": "failed", "error": "Bad input"]), .failed(message: "Bad input")),
            (.object(["status": "ip_detected"]), .rejected(.protectedContent)),
            (.object(["status": "nsfw"]), .rejected(.explicitContent)),
            (.object(["status": "cancelled"]), .canceled),
            (
                .object(["status": "completed", "results": ["rawUrl": "https://cdn.example/out.mp4"]]),
                .completed(videoURL: URL(string: "https://cdn.example/out.mp4")!)
            ),
        ])
        func statusReadsTheGeneration(generation: JSONValue, expected: GenerationStatus) async throws {
            let (account, stub) = Self.account { _, _ in ["generation": generation] }
            #expect(try await account.status(of: "job-1") == expected)
            #expect(Self.calls(stub).first?["arguments"] == ["jobId": "job-1"])
        }

        @Test(arguments: [JSONValue.object(["status": "teleporting"]), .object([:])])
        func unknownStatusKeepsPolling(generation: JSONValue) async throws {
            let (account, _) = Self.account { _, _ in ["generation": generation] }
            #expect(try await account.status(of: "job-1") == .inProgress)
        }

        @Test(arguments: [
            JSONValue.object(["error": "Job not found"]), .object(["generation": ["status": "completed"]]),
            .object(["generation": ["status": "completed", "results": ["rawUrl": "file:///home/me/Movies/x.mov"]]]),
        ])
        func answerWithoutGenerationOrVideoIsUnexpected(answer: JSONValue) async throws {
            let (account, _) = Self.account { _, _ in answer }
            await #expect(
                throws: HiggsfieldError.validation(field: nil, message: "Unexpected result from the job_status tool")
            ) {
                try await account.status(of: "job-1")
            }
        }

        /// Neither a generation nor an error: the job may be paid and running, so it is polled again.
        @Test func anEmptyAnswerIsPolledAgain() async throws {
            let (account, _) = Self.account { _, _ in [:] }
            await #expect(throws: HiggsfieldError.server(status: 200)) { try await account.status(of: "job-1") }
        }

        @Test func toolAddedLaterIsFoundByListingAgain() async throws {
            let tools = Locked(Self.withoutGenerate)
            let (account, stub) = Self.account(tools: tools) { _, _ in ["results": [["id": "job-1"]]] }
            #expect(try await !account.refreshTools())

            tools.update { $0 = Self.fullSet }
            #expect(try await account.generate(Self.request).id == "job-1")
            #expect(Self.listings(stub) == 2)
        }

        @Test func stillMissingToolIsUnavailableAfterOneMoreListing() async throws {
            let (account, stub) = Self.account(tools: Self.withoutGenerate)
            #expect(try await !account.refreshTools())

            await #expect(throws: HiggsfieldError.toolUnavailable("generate_video")) {
                try await account.generate(Self.request)
            }
            #expect(Self.listings(stub) == 2)
            #expect(Self.calls(stub).isEmpty)
        }

        @Test func missingBalanceIsListedAgainOnlyOnceTheCatalogIsAMinuteOld() async throws {
            let tools = Locked(Self.fullSet.filter { $0["name"] != "balance" })
            let now = Locked(Date(timeIntervalSince1970: 0))
            let (account, stub) = Self.account(tools: tools, now: now) { _, _ in ["credits": 10] }
            #expect(try await account.balance() == nil)
            tools.update { $0 = Self.fullSet }
            now.update { $0 += 59 }
            #expect(try await account.balance() == nil)
            #expect(Self.listings(stub) == 1)

            now.update { $0 += 1 }
            #expect(try await account.balance() == AccountBalance(credits: 10, plan: nil))
            #expect(Self.listings(stub) == 2)
        }

        @Test func declinedGenerationCarriesTheServerReason() async throws {
            let (account, _) = Self.account { _, _ in ["error": "Not enough credits"] }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Not enough credits")) {
                try await account.generate(Self.request)
            }
        }

        @Test func balanceReadsCreditsAndPlan() async throws {
            let (account, _) = Self.account { _, _ in ["credits": .number(2596.34), "subscription_plan_type": "ultra"] }
            #expect(try await account.balance() == AccountBalance(credits: 2596.34, plan: "ultra"))
        }

        @Test func uploadPutsTheFileAndConfirmsItsMediaID() async throws {
            let mcp = mcpServer(tools: Self.fullSet) { name, _ in
                name == "media_upload"
                    ? [
                        "uploads": [
                            [
                                "media_id": "media-1", "upload_url": "https://upload.example/in.png?X-Signature=abc",
                                "url": "https://cdn.example/media-1.png",
                            ]
                        ]
                    ]
                    : ["results": [["media_id": "media-1", "status": "uploaded"]]]
            }
            let stub = StubServer { request, _ in request.method == "PUT" ? StubResponse() : mcp.respond(to: request) }
            let session = stub.session()
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: session)
            let account = HiggsfieldAccount(client: client, session: session)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
            try Data("png".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let media = try await account.upload(fileAt: file, contentType: "image/png")

            let url = try #require(URL(string: "https://cdn.example/media-1.png"))
            #expect(media == UploadedMedia(id: "media-1", url: url))
            let put = try #require(stub.requests.first { $0.method == "PUT" })
            #expect(put.header("Authorization") == nil)
            #expect(put.header("Content-Type") == "image/png")
            #expect(Self.calls(stub).last?["arguments"] == ["media_id": "media-1", "type": "image"])
        }

        @Test func uploadURLThatIsNotHTTPSIsNeverOpened() async throws {
            let mcp = mcpServer(tools: Self.fullSet) { _, _ in
                [
                    "uploads": [
                        ["media_id": "m", "upload_url": "http://upload.example/x", "url": "https://cdn.example/x"]
                    ]
                ]
            }
            let stub = StubServer { request, _ in request.method == "PUT" ? StubResponse() : mcp.respond(to: request) }
            let session = stub.session()
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: session)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try Data("mp4".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            await #expect(
                throws: HiggsfieldError.validation(field: nil, message: "Unexpected result from the media_upload tool")
            ) {
                try await HiggsfieldAccount(client: client, session: session).upload(
                    fileAt: file, contentType: "video/mp4")
            }
            #expect(!stub.requests.contains { $0.method == "PUT" })
        }

        /// An account whose server answers `method` with `result`, which doesn't decode.
        static func account(answering method: String, with result: JSONValue) -> HiggsfieldAccount {
            let answering = mcpServer(tools: fullSet)
            let stub = StubServer { request, _ in
                guard let id = request.json?["id"], request.json?["method"]?.stringValue == method else {
                    return answering.respond(to: request)
                }
                return .json(["jsonrpc": "2.0", "id": id, "result": result])
            }
            let session = stub.session()
            return HiggsfieldAccount(
                client: MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: session),
                session: session)
        }

        @Test func unreadableRepliesAreServerErrors() async throws {
            let list = Self.account(answering: "tools/list", with: ["tools": "none"])
            await #expect(throws: HiggsfieldError.server(status: 200)) { try await list.refreshTools() }

            let call = Self.account(answering: "tools/call", with: ["content": "not a list"])
            await #expect(throws: HiggsfieldError.server(status: 200)) { try await call.balance() }
        }

        @Test func refusedPutIsAServerError() async throws {
            let mcp = mcpServer(tools: Self.fullSet) { _, _ in
                [
                    "uploads": [
                        ["media_id": "m", "upload_url": "https://upload.example/x", "url": "https://cdn.example/x"]
                    ]
                ]
            }
            let stub = StubServer { request, _ in
                request.method == "PUT" ? StubResponse(status: 403) : mcp.respond(to: request)
            }
            let session = stub.session()
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: session)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try Data("mp4".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            await #expect(throws: HiggsfieldError.server(status: 403)) {
                try await HiggsfieldAccount(client: client, session: session).upload(
                    fileAt: file, contentType: "video/mp4")
            }
        }
    }
}
