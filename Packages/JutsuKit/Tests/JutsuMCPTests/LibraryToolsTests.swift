import Foundation
import HiggsfieldMCP
import JutsuAgent
import Testing

@testable import JutsuMCP

/// create_image, the Library tools and stage 2's paging, as the helper turns them into commands.
@Suite struct LibraryToolsTests {
    private let app = FakeApp(AgentResponse(created: AgentCreated(requestID: "img-1", known: false, jobs: [])))
    private let inbox = FakeInbox()
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")

    private func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let (app, inbox) = (app, inbox)
        var server = MCPServer(
            version: "0.3.0", stage: { path, request, _ in await inbox.stage(path, request) },
            send: { await app.receive($0, $1) })
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

    private func image(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "request_id": "img-1", "prompt": "a red fox", "max_cost": ["amount": 40, "unit": "credits"],
        ]
        for (key, value) in extra { arguments[key] = value }
        return arguments
    }

    private func command(_ tool: Tool, _ arguments: [String: JSONValue]) -> Result<AgentCommand, AgentError> {
        tool.command(arguments, workingDirectory: folder)
    }

    // MARK: create_image

    @Test func createImageStagesItsInputThenSendsTheCopy() async throws {
        let input = try file("fox.png")
        let result = try await call("create_image", .object(image(["input": .string(input), "count": 4])))

        #expect(result["isError"] == false)
        let staged = await inbox.staged
        #expect(staged.map(\.path) == [input])
        #expect(staged.first?.request.command == "create_image")
        guard case .createImage(let command)? = await app.calls.first?.0 else {
            Issue.record("create_image wasn't sent")
            return
        }
        #expect(command.image.input == "/tmp/inbox/1/fox.png")
        #expect(command.image.count == 4)
        #expect(command.fingerprint == staged.first?.request.fingerprint)
        #expect(command.maxCost == AgentAmount(40, .credits))
    }

    @Test func aConflictingImageRequestStopsBeforeAnyByteOrCommand() async throws {
        await inbox.refuse(with: .requestConflict)
        let result = try await call("create_image", .object(image(["input": .string(try file("fox.png"))])))
        #expect(result["structuredContent"]?["error"]?["code"] == "request_conflict")
        #expect(await app.calls.isEmpty)
    }

    @Test func theImageFingerprintFollowsTheRequestAndIsNeverAVideos() throws {
        let input = try file("fox.png")
        func fingerprint(_ arguments: [String: JSONValue]) throws -> String {
            guard case .success(.createImage(let command)) = command(.createImage, arguments) else {
                throw AgentError.badRequest("not a create_image")
            }
            return command.fingerprint
        }
        let first = try fingerprint(image(["input": .string(input)]))
        #expect(try fingerprint(image(["input": .string(input)])) == first)
        #expect(try fingerprint(image(["input": .string(input), "count": 4])) != first)
        #expect(
            try fingerprint(image(["max_cost": ["amount": 41, "unit": "credits"], "input": .string(input)])) != first)
        try Data(repeating: 2, count: 9).write(to: URL(filePath: input))
        #expect(try fingerprint(image(["input": .string(input)])) != first)
        guard
            case .success(.createVideo(let video)) = command(
                .createVideo,
                [
                    "request_id": "img-1", "mode": "restyle", "prompt": "a red fox",
                    "max_cost": ["amount": 40, "unit": "credits"],
                ])
        else {
            Issue.record("no create_video")
            return
        }
        #expect(video.fingerprint != first)
    }

    @Test func badImageArgumentsNeverReachTheApp() {
        let bad: [[String: JSONValue]] = [
            image(["request_id": .null]), image(["max_cost": .null]), image(["prompt": "  "]), image(["count": 0]),
            image(["count": 17]), image(["model": "../x"]), image(["size": "big"]),
        ]
        for arguments in bad {
            guard case .failure(let error) = command(.createImage, arguments) else {
                Issue.record("taken: \(arguments)")
                continue
            }
            #expect(error.code == .badRequest)
        }
    }

    // MARK: The Library

    @Test func librarySearchTakesItsFilters() throws {
        let result = command(
            .librarySearch,
            [
                "query": "fox", "kind": "video", "starred": false, "verdict": "kept", "mode": "restyle",
                "from": "2026-10-01T00:00:00Z", "to": "2026-10-21T00:00:00.500Z", "limit": 5, "cursor": "abc_1",
            ])
        guard case .success(.librarySearch(let search)) = result else {
            Issue.record("no library_search: \(result)")
            return
        }
        #expect(search.kind == .video)
        #expect(search.starred == false)
        #expect(search.verdict == .kept)
        #expect(search.from == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        #expect(search.to != nil)
        for bad in [
            ["kind": "audio"], ["from": "yesterday"], ["limit": 51], ["mode": "dance"], ["cursor": "a b"],
            ["from": "2026-10-02T00:00:00Z", "to": "2026-10-01T00:00:00Z"],
        ] as [[String: JSONValue]] {
            guard case .failure = command(.librarySearch, bad) else {
                Issue.record("taken: \(bad)")
                continue
            }
        }
    }

    @Test func libraryMarkNeedsSomethingToMark() {
        let id = UUID().uuidString
        guard case .success(.libraryMark(let mark)) = command(.libraryMark, ["ids": [.string(id)], "star": true]) else {
            Issue.record("no library_mark")
            return
        }
        #expect(mark.star == true && mark.verdict == nil)
        for bad in [["ids": [.string(id)]], ["ids": [], "star": true], ["ids": [.string(id)], "verdict": "delete"]]
            as [[String: JSONValue]]
        {
            guard case .failure = command(.libraryMark, bad) else {
                Issue.record("taken: \(bad)")
                continue
            }
        }
    }

    @Test func enhanceIsFingerprintedAndChecksItsOptions() throws {
        let item = UUID().uuidString
        let base: [String: JSONValue] = [
            "request_id": "up-1", "item": .string(item), "operation": "upscale", "target": "4k",
            "max_cost": ["amount": 20, "unit": "credits"],
        ]
        guard case .success(.enhance(let first)) = command(.enhance, base) else {
            Issue.record("no enhance")
            return
        }
        #expect(first.target == "4k")
        var other = base
        other["target"] = "2k"
        guard case .success(.enhance(let second)) = command(.enhance, other) else {
            Issue.record("no enhance")
            return
        }
        #expect(first.fingerprint != second.fingerprint)
        #expect(AgentNames.isValidFingerprint(first.fingerprint))
        var wrong = base
        wrong["language"] = "fra"
        guard case .failure = command(.enhance, wrong) else {
            Issue.record("upscale took a language")
            return
        }
    }

    @Test func deliverySetAndExportCommands() {
        let id = UUID().uuidString
        guard
            case .success(.deliverySet(let create)) = command(
                .deliverySet, ["action": "create", "items": [.string(id)]])
        else {
            Issue.record("no delivery_set")
            return
        }
        #expect(create.items.count == 1)
        guard case .failure = command(.deliverySet, ["action": "export"]) else {
            Issue.record("export without a set")
            return
        }
        guard case .success(.export(let export)) = command(.export, ["items": [.string(id)], "preset": "premiere"])
        else {
            Issue.record("no export")
            return
        }
        #expect(export.preset == .premiere)
        guard case .failure = command(.export, ["items": [.string(id), .string(id)], "preset": "premiere"]) else {
            Issue.record("the same video twice")
            return
        }
    }

    @Test func jobsPagesWithACursorAndCapabilitiesListsMore() {
        guard case .success(.jobs(let jobs)) = command(.jobs, ["cursor": "1729500000123_ABC"]) else {
            Issue.record("no jobs")
            return
        }
        #expect(jobs.cursor == "1729500000123_ABC")
        guard case .failure = command(.jobs, ["cursor": "x", "ids": [.string(UUID().uuidString)]]) else {
            Issue.record("a cursor with ids")
            return
        }
        guard
            case .success(.capabilities(let capabilities)) = command(
                .capabilities, ["image_models": true, "styles": true, "voices": true])
        else {
            Issue.record("no capabilities")
            return
        }
        #expect(capabilities.imageModels && capabilities.styles && capabilities.voices)
    }

    @Test func theLibrarysAnswersAreToolResults() {
        let answers = [
            AgentResponse(library: AgentLibraryPage(items: [], nextCursor: "c")),
            AgentResponse(marked: AgentMarked(items: [], changed: 0)),
            AgentResponse(delivery: AgentDelivery(action: .list, sets: [], folders: [])),
            AgentResponse(exported: AgentExported(folder: "/tmp/Exports", files: [])),
        ]
        for answer in answers {
            let result = MCPServer.toolResult(answer, structured: true)
            #expect(result["isError"] == false)
            #expect(result["structuredContent"]?["error"] == nil)
        }
        #expect(MCPServer.toolResult(answers[0], structured: true)["structuredContent"]?["nextCursor"] == "c")
    }
}
