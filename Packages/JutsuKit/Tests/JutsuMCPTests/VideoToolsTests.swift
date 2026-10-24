import Foundation
import HiggsfieldMCP
import JutsuAgent
import Testing

@testable import JutsuMCP

/// What the fake app staged for each file.
actor FakeInbox {
    var staged: [(path: String, request: UploadRequest)] = []
    /// Answered instead of staging, when set.
    var refusal: AgentError?

    func stage(_ path: String, _ request: UploadRequest) -> Result<String, AgentError> {
        if let refusal { return .failure(refusal) }
        staged.append((path, request))
        return .success("/tmp/inbox/\(staged.count)/\(URL(filePath: path).lastPathComponent)")
    }

    func refuse(with error: AgentError) { refusal = error }
}

@Suite struct VideoToolsTests {
    private let app = FakeApp(AgentResponse(created: AgentCreated(requestID: "r1", known: false, jobs: [])))
    private let inbox = FakeInbox()
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")

    private func server() -> MCPServer {
        let (app, inbox) = (app, inbox)
        return MCPServer(
            version: "0.2.0", stage: { path, request, _ in await inbox.stage(path, request) },
            send: { await app.receive($0, $1) })
    }

    private func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        var server = server()
        let message: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": .string(name), "arguments": arguments],
        ]
        let data = try #require(await server.reply(to: JSONEncoder().encode(message)))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: data)["result"])
    }

    private func file(_ name: String, bytes: Int = 3) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private func create(_ extra: [String: JSONValue] = [:], source: String? = nil) -> JSONValue {
        var arguments: [String: JSONValue] = [
            "request_id": "r1", "mode": "motion_transfer", "max_cost": ["amount": .number(2.509), "unit": "usd"],
        ]
        if let source { arguments["source"] = ["path": .string(source), "start": 1, "end": 6] }
        for (key, value) in extra { arguments[key] = value }
        return .object(arguments)
    }

    @Test func createVideoStagesEachFileForItsRequestThenSendsTheirCopies() async throws {
        let source = try file("clip.mov")
        let image = try file("face.png")

        let result = try await call("create_video", create(["images": [.string(image)]], source: source))

        #expect(result["isError"] == false)
        let staged = await inbox.staged
        #expect(staged.map(\.path) == [source, image])
        #expect(Set(staged.map(\.request)).count == 1)
        #expect(staged.first?.request.requestID == "r1")
        #expect(staged.first?.request.command == "create_video")
        guard case .createVideo(let command)? = await app.calls.first?.0 else {
            Issue.record("create_video wasn't sent")
            return
        }
        #expect(command.video.source?.path == "/tmp/inbox/1/clip.mov")
        #expect(command.video.images == ["/tmp/inbox/2/face.png"])
        #expect(command.fingerprint == staged.first?.request.fingerprint)
        #expect(command.parameters != nil && command.parameters == staged.first?.request.parameters)
        // Dollars become whole cents, rounded down.
        #expect(command.maxCost == AgentAmount(250, .usdCents))
    }

    /// The same request gives the same fingerprint; any change, another one.
    @Test func theFingerprintFollowsTheParametersAndTheFiles() async throws {
        let source = try file("clip.mov")
        func fingerprint(_ arguments: JSONValue) throws -> String {
            guard case .success(.createVideo(let command)) = Tool.createVideo.command(arguments.objectValue ?? [:])
            else { throw AgentError.badRequest("not a create_video") }
            return command.fingerprint
        }
        let first = try fingerprint(create(source: source))
        #expect(try fingerprint(create(source: source)) == first)
        #expect(try fingerprint(create(["prompt": "other"], source: source)) != first)
        #expect(try fingerprint(create(["max_cost": ["amount": 3, "unit": "usd"]], source: source)) != first)
        try Data(repeating: 2, count: 10).write(to: URL(filePath: source))
        #expect(try fingerprint(create(source: source)) != first)
    }

    /// The parameters' digest leaves out max_cost only: a higher max_cost is the same parameters, anything else isn't.
    @Test func theParametersFollowEverythingButMaxCost() async throws {
        let source = try file("clip.mov")
        func digests(_ arguments: JSONValue) throws -> (fingerprint: String, parameters: String?) {
            guard case .success(.createVideo(let command)) = Tool.createVideo.command(arguments.objectValue ?? [:])
            else { throw AgentError.badRequest("not a create_video") }
            return (command.fingerprint, command.parameters)
        }
        let first = try digests(create(source: source))
        let raised = try digests(create(["max_cost": ["amount": 3, "unit": "usd"]], source: source))
        #expect(raised.fingerprint != first.fingerprint && raised.parameters == first.parameters)
        #expect(first.parameters != first.fingerprint)
        #expect(try digests(create(["prompt": "other"], source: source)).parameters != first.parameters)
        try Data(repeating: 2, count: 10).write(to: URL(filePath: source))
        #expect(try digests(create(source: source)).parameters != first.parameters)
    }

    /// wait_seconds is how the call answers, not what it asks for: a retry with another wait is the same request.
    @Test func aWaitIsSentButIsNotPartOfTheRequest() async throws {
        let source = try file("clip.mov")
        guard
            case .success(.createVideo(let waiting)) = Tool.createVideo.command(
                create(["wait_seconds": 30], source: source).objectValue ?? [:]),
            case .success(.createVideo(let plain)) = Tool.createVideo.command(create(source: source).objectValue ?? [:])
        else {
            Issue.record("no create_video")
            return
        }
        #expect(waiting.waitSeconds == 30 && plain.waitSeconds == 0)
        #expect(waiting.fingerprint == plain.fingerprint)
        let long = try await call("create_video", create(["wait_seconds": 51]))
        #expect(long["structuredContent"]?["error"]?["code"] == "bad_request")
    }

    /// A title goes to the app as the agent wrote it, and is part of the request; one past the protocol's bound is
    /// refused before anything is sent.
    @Test func aTitleIsSentWithTheRequest() async throws {
        let source = try file("clip.mov")
        guard
            case .success(.createVideo(let titled)) = Tool.createVideo.command(
                create(["title": "Knight, take 3"], source: source).objectValue ?? [:])
        else {
            Issue.record("no create_video")
            return
        }
        #expect(titled.video.title == "Knight, take 3")
        guard
            case .success(.createVideo(let plain)) = Tool.createVideo.command(create(source: source).objectValue ?? [:])
        else {
            Issue.record("no create_video")
            return
        }
        #expect(plain.video.title == nil && plain.fingerprint != titled.fingerprint)
        let long = try await call("create_video", create(["title": .string(String(repeating: "a", count: 1_001))]))
        #expect(long["structuredContent"]?["error"]?["code"] == "bad_request")
        let image = try await call(
            "create_image",
            [
                "request_id": "i1", "prompt": "a fox", "title": .string(String(repeating: "a", count: 1_001)),
                "max_cost": ["amount": 1, "unit": "usd"],
            ])
        #expect(image["structuredContent"]?["error"]?["code"] == "bad_request")
        #expect(await app.calls.isEmpty)
    }

    /// A request the app already queued: nothing more is uploaded, and the command still goes for its job.
    @Test func aKnownRequestSkipsTheUploadsAndStillGetsItsJob() async throws {
        let source = try file("clip.mov")
        await inbox.refuse(with: AgentError(.requestKnown, message: "known", retryable: false))

        let result = try await call("create_video", create(["images": [.string(try file("a.png"))]], source: source))

        #expect(result["isError"] == false)
        guard case .createVideo(let command)? = await app.calls.first?.0 else {
            Issue.record("create_video wasn't sent")
            return
        }
        #expect(command.video.source?.path == nil)
        #expect(command.video.images.isEmpty)
    }

    /// A conflicting request ID is refused at the first upload; no command follows.
    @Test func aConflictStopsBeforeTheCommand() async throws {
        await inbox.refuse(with: .requestConflict)

        let result = try await call("create_video", create(source: try file("clip.mov")))

        #expect(result["structuredContent"]?["error"]?["code"] == "request_conflict")
        #expect(await app.calls.isEmpty)
    }

    @Test func badVideoArgumentsNeverReachTheApp() async throws {
        let cases: [(String, JSONValue)] = [
            ("create_video", ["mode": "motion_transfer", "max_cost": ["amount": 1, "unit": "usd"]]),
            ("create_video", ["request_id": "r1", "mode": "motion_transfer"]),
            (
                "create_video",
                ["request_id": "../x", "mode": "motion_transfer", "max_cost": ["amount": 1, "unit": "usd"]]
            ),
            ("create_video", ["request_id": "r1", "mode": "dance", "max_cost": ["amount": 1, "unit": "usd"]]),
            ("create_video", ["request_id": "r1", "mode": "restyle", "max_cost": ["amount": -1, "unit": "usd"]]),
            (
                "create_video",
                ["request_id": "r1", "mode": "restyle", "max_cost": ["amount": .number(1e20), "unit": "usd"]]
            ),
            ("create_video", ["request_id": "r1", "mode": "restyle", "max_cost": ["amount": 1, "unit": "eur"]]),
            ("quote", ["mode": "edit", "source": ["start": 5, "end": 2]]),
            ("quote", ["mode": "edit", "source": ["end": .number(1e30)]]),
            ("quote", ["mode": "edit", "length": 0]),
            ("quote", ["mode": "edit", "variants": 0]),
            ("jobs", ["wait_seconds": 51]),
            ("jobs", ["ids": ["nope"]]),
            ("jobs", ["limit": 0]),
            ("job_action", ["action": "delete", "job": .string(UUID().uuidString)]),
            ("job_action", ["action": "cancel"]),
            ("job_action", ["action": "pause_queue", "job": .string(UUID().uuidString)]),
        ]
        for (name, arguments) in cases {
            let result = try await call(name, arguments)
            #expect(result["structuredContent"]?["error"]?["code"] == "bad_request", "\(name) \(arguments)")
        }
        #expect(await app.calls.isEmpty)
        #expect(await inbox.staged.isEmpty)
    }

    @Test func aQuoteSendsNoFilesOnlyHowManyThereAre() async throws {
        _ = try await call(
            "quote", ["mode": "motion_transfer", "images": ["/tmp/a.png", "/tmp/b.png"], "source": ["end": 8]])

        #expect(await inbox.staged.isEmpty)
        #expect(
            await app.calls.first?.0
                == .quote(
                    QuoteCommand(
                        video: AgentVideoRequest(
                            mode: "motion_transfer", source: AgentSource(end: 8), imageCount: 2))))
    }

    @Test func jobsAndActionsBecomeTheirCommands() async throws {
        let id = UUID()
        _ = try await call("jobs", ["ids": [.string(id.uuidString)], "wait_seconds": 50])
        _ = try await call("job_action", ["action": "retry", "job": .string(id.uuidString)])
        _ = try await call("job_action", ["action": "resume_queue"])

        #expect(
            await app.calls.map(\.0) == [
                .jobs(JobsCommand(ids: [id], waitSeconds: 50)),
                .jobAction(JobActionCommand(action: .retry, job: id)),
                .jobAction(JobActionCommand(action: .resumeQueue)),
            ])
    }

    /// Every new answer reaches the agent as structured content.
    @Test func newAnswersAreToolResults() {
        let job = AgentJob(
            id: UUID(), state: "paused", pauseReason: "agent_limit", hold: "over_max_cost",
            needsPerson: true, mode: "restyle", model: "genjutsu", createdAt: Date(timeIntervalSince1970: 0))
        let answers = [
            AgentResponse(
                quote: AgentQuote(
                    price: AgentAmount(130, .usdCents), isExact: true, mode: "restyle",
                    model: "genjutsu", resolution: "720p", duration: 5, remainingToday: 870, blocker: nil)),
            AgentResponse(created: AgentCreated(requestID: "r1", known: true, jobs: [job])),
            AgentResponse(jobs: AgentJobs(jobs: [job], timedOut: true)),
            AgentResponse(acted: AgentActed(action: .cancel, job: job)),
        ]
        for answer in answers {
            let result = MCPServer.toolResult(answer, structured: true)
            #expect(result["isError"] == false)
            #expect(result["structuredContent"]?["error"] == nil)
        }
        let jobs = MCPServer.toolResult(answers[2], structured: true)["structuredContent"]
        #expect(jobs?["timedOut"] == true)
        #expect(jobs?["jobs"]?.arrayValue?.first?["hold"] == "over_max_cost")
    }
}
