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
        #expect(command.image.inputs == ["/tmp/inbox/1/fox.png"])
        #expect(command.image.count == 4)
        #expect(command.fingerprint == staged.first?.request.fingerprint)
        #expect(command.maxCost == AgentAmount(40, .credits))
    }

    /// inputs are staged and sent in order; input is the same request with one image, so it keeps its fingerprint.
    @Test func severalInputsAreStagedInOrderAndInputIsTheirOneItemForm() async throws {
        let paths = try ["a.png", "b.png", "c.png"].map { try file($0) }
        let result = try await call("create_image", .object(image(["inputs": .array(paths.map { .string($0) })])))
        #expect(result["isError"] == false)
        #expect(await inbox.staged.map(\.path) == paths)
        guard case .createImage(let staged)? = await app.calls.first?.0 else {
            Issue.record("create_image wasn't sent")
            return
        }
        #expect(staged.image.inputs.count == 3)
        #expect(staged.image.inputs.allSatisfy { $0.hasPrefix("/tmp/inbox/") })

        func sent(_ arguments: [String: JSONValue]) throws -> CreateImageCommand {
            guard case .success(.createImage(let command)) = self.command(.createImage, arguments) else {
                throw AgentError.badRequest("not a create_image")
            }
            return command
        }
        let one = try sent(image(["input": .string(paths[0])]))
        #expect(try sent(image(["inputs": [.string(paths[0])]])).fingerprint == one.fingerprint)
        // The wire keeps one input as `input`, as before.
        let line = String(decoding: try AgentWire.line(AgentRequest(.createImage(one))), as: UTF8.self)
        #expect(line.contains("\"input\":") && !line.contains("\"inputs\""))
        let decoded = AgentWire.request(from: try AgentWire.line(AgentRequest(.createImage(one)))).request
        #expect(try decoded.get().command == .createImage(one))

        for bad in [
            image(["input": .string(paths[0]), "inputs": [.string(paths[1])]]),
            image(["inputs": .array((0...16).map { .string("/tmp/\($0).png") })]), image(["inputs": "a.png"]),
        ] {
            guard case .failure(let error) = command(.createImage, bad) else {
                Issue.record("taken: \(bad)")
                continue
            }
            #expect(error.code == .badRequest)
        }
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
        #expect(search.includeHiggsfield == nil)
        guard
            case .success(.librarySearch(let history)) = command(
                .librarySearch, ["include_higgsfield": true, "refresh_higgsfield": true])
        else {
            Issue.record("no library_search of the history")
            return
        }
        #expect(history.includeHiggsfield == true && history.refreshHiggsfield == true)
        for bad in [
            ["kind": "audio"], ["from": "yesterday"], ["limit": 51], ["mode": "dance"], ["cursor": "a b"],
            ["refresh_higgsfield": true],
            ["from": "2026-10-02T00:00:00Z", "to": "2026-10-01T00:00:00Z"],
        ] as [[String: JSONValue]] {
            guard case .failure = command(.librarySearch, bad) else {
                Issue.record("taken: \(bad)")
                continue
            }
        }
    }

    @Test func libraryDownloadTakesUpToTwentyItemIDs() {
        let id = UUID().uuidString
        guard case .success(.libraryDownload(let download)) = command(.libraryDownload, ["ids": [.string(id)]]) else {
            Issue.record("no library_download")
            return
        }
        #expect(download.ids.map(\.uuidString) == [id])
        for bad in [
            [:], ["ids": []], ["ids": [.string(id), .string(id)]], ["ids": ["nope"]],
            ["ids": .array((0...20).map { _ in .string(UUID().uuidString) })],
        ] as [[String: JSONValue]] {
            guard case .failure = command(.libraryDownload, bad) else {
                Issue.record("taken: \(bad)")
                continue
            }
        }
    }

    @Test func libraryGetTakesUpToTwentyItemIDs() {
        let id = UUID().uuidString
        guard case .success(.libraryGet(let get)) = command(.libraryGet, ["ids": [.string(id)]]) else {
            Issue.record("no library_get")
            return
        }
        #expect(get.ids.map(\.uuidString) == [id])
        for bad in [
            ["ids": []], ["ids": [.string(id), .string(id)]], ["ids": ["not-an-id"]],
            ["ids": [.string(id)], "full": true],
            ["ids": .array((0...20).map { _ in .string(UUID().uuidString) })],
        ] as [[String: JSONValue]] {
            guard case .failure = command(.libraryGet, bad) else {
                Issue.record("taken: \(bad)")
                continue
            }
        }
        let answer = AgentResponse(details: AgentLibraryDetailsPage(items: []))
        #expect(MCPServer.toolResult(answer, structured: true)["isError"] == false)
    }

    /// frames' own files are staged under a request named by its fingerprint, then the command goes with inbox paths.
    @Test func framesStagesItsFilesAndSendsTheCommand() async throws {
        let (main, other) = (try file("take.mov"), try file("source.mov"))
        let result = try await call(
            "frames", ["file": .string(main), "times": [.number(1), .number(2.5)], "compare_file": .string(other)])
        #expect(result["isError"] == false)
        #expect(await inbox.staged.map(\.path) == [main, other])
        #expect(await inbox.staged.allSatisfy { $0.request.command == "frames" })
        guard case .frames(let staged)? = await app.calls.first?.0 else {
            Issue.record("frames wasn't sent")
            return
        }
        #expect(staged.times == [1, 2.5])
        #expect(staged.files.allSatisfy { $0.hasPrefix("/tmp/inbox/") })
    }

    @Test func framesTakesOneClipAndAtMostOneComparison() {
        let id = UUID().uuidString
        let asked: [String: JSONValue] = ["item": .string(id), "times": [0], "compare_source": true]
        guard case .success(.frames(let item)) = command(.frames, asked) else {
            Issue.record("no frames")
            return
        }
        #expect(item.compareSource && item.item?.uuidString == id)
        for bad in [
            ["times": [1]], ["item": .string(id), "file": "/tmp/a.mov", "times": [1]], ["item": .string(id)],
            ["item": .string(id), "times": []],
            ["item": .string(id), "times": .array((0...12).map { .number(Double($0)) })],
            ["item": .string(id), "times": [-1]], ["file": "/tmp/a.mov", "times": [1], "compare_source": true],
            ["item": .string(id), "times": [1], "compare_item": .string(id), "compare_file": "/tmp/b.mov"],
            ["item": "nope", "times": [1]],
        ] as [[String: JSONValue]] {
            guard case .failure(let error) = command(.frames, bad) else {
                Issue.record("taken: \(bad)")
                continue
            }
            #expect(error.code == .badRequest)
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
        #expect(export.waitSeconds == nil)
        guard case .failure = command(.export, ["items": [.string(id), .string(id)], "preset": "premiere"]) else {
            Issue.record("the same video twice")
            return
        }
    }

    /// An export answers with its handle; a wait for it is as bounded as a jobs wait, and only an export waits.
    @Test func exportsTakeABoundedWait() {
        let id = UUID().uuidString
        guard
            case .success(.export(let export)) = command(
                .export, ["items": [.string(id)], "preset": "premiere", "wait_seconds": 50])
        else {
            Issue.record("no export")
            return
        }
        #expect(export.waitSeconds == 50)
        let set = UUID().uuidString
        guard
            case .success(.deliverySet(let delivery)) = command(
                .deliverySet, ["action": "export", "set": .string(set), "wait_seconds": 10])
        else {
            Issue.record("no delivery export")
            return
        }
        #expect(delivery.waitSeconds == 10)
        let refused: [(Tool, [String: JSONValue])] = [
            (.export, ["items": [.string(id)], "preset": "premiere", "wait_seconds": 51]),
            (.export, ["items": [.string(id)], "preset": "premiere", "wait_seconds": -1]),
            (.deliverySet, ["action": "list", "wait_seconds": 5]),
        ]
        for (tool, arguments) in refused {
            guard case .failure = command(tool, arguments) else {
                Issue.record("\(tool.rawValue) took \(arguments)")
                continue
            }
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
            AgentResponse(
                exported: AgentExported(job: AgentJob(id: UUID(), state: "processing", kind: "export", createdAt: .now))
            ),
        ]
        for answer in answers {
            let result = MCPServer.toolResult(answer, structured: true)
            #expect(result["isError"] == false)
            #expect(result["structuredContent"]?["error"] == nil)
        }
        #expect(MCPServer.toolResult(answers[0], structured: true)["structuredContent"]?["nextCursor"] == "c")
    }
}
