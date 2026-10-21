import Foundation
import HiggsfieldMCP
import JutsuAgent
import Testing

@testable import JutsuMCP

/// What the fake app was asked, and what it answers.
actor FakeApp {
    var calls: [(AgentCommand, String?)] = []
    var answer: AgentResponse

    init(_ answer: AgentResponse) { self.answer = answer }

    func receive(_ command: AgentCommand, _ client: String?) -> AgentResponse {
        calls.append((command, client))
        return answer
    }
}

@Suite struct MCPServerTests {
    static let capabilities = AgentCapabilities(
        appVersion: "0.2.0", connection: .init(kind: .account, plan: "Pro", credits: 1200),
        budget: .init(unit: .credits, dailyLimit: 0, spentToday: 0))

    private let app = FakeApp(AgentResponse(capabilities: Self.capabilities))

    private func server() -> MCPServer {
        let app = app
        return MCPServer(version: "0.2.0") { await app.receive($0, $1) }
    }

    private static let modernMeta: JSONValue = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
        "io.modelcontextprotocol/clientInfo": ["name": "agent-cli", "title": "Agent CLI", "version": "1"],
    ]

    /// One request through `server`, and its reply as JSON.
    private func reply(
        _ server: inout MCPServer, _ method: String, _ params: JSONValue? = nil, id: JSONValue = 1
    ) async throws -> JSONValue {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
        message["params"] = params
        return try await reply(&server, line: JSONEncoder().encode(JSONValue.object(message)))
    }

    private func reply(_ server: inout MCPServer, line: Data) async throws -> JSONValue {
        let data = try #require(await server.reply(to: line))
        #expect(data.last == UInt8(ascii: "\n"))
        #expect(!data.dropLast().contains(UInt8(ascii: "\n")))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func reply(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        var server = server()
        return try await reply(&server, method, params)
    }

    // MARK: 2026-07-28

    @Test func discoverDescribesTheServerStatelessly() async throws {
        let answer = try await reply("server/discover", ["_meta": Self.modernMeta])
        let result = try #require(answer["result"])
        #expect(answer["id"] == 1)
        #expect(result["resultType"] == "complete")
        #expect(result["supportedVersions"]?.arrayValue?.first == "2026-07-28")
        #expect(result["supportedVersions"]?.arrayValue?.contains("2025-11-25") == true)
        #expect(result["capabilities"] == ["tools": ["listChanged": false]])
        #expect(result["instructions"]?.stringValue?.contains("Allow agents") == true)
        #expect(result["ttlMs"]?.numberValue ?? 0 > 0)
        #expect(result["cacheScope"] == "public")
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "jutsu")
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["version"] == "0.2.0")
    }

    @Test func anUnsupportedVersionIsRefusedWithTheSupportedOnes() async throws {
        let meta: JSONValue = [
            "io.modelcontextprotocol/protocolVersion": "1900-01-01", "io.modelcontextprotocol/clientCapabilities": [:],
        ]
        let error = try #require(try await reply("tools/list", ["_meta": meta])["error"])
        #expect(error["code"]?.numberValue == -32022)
        #expect(error["data"]?["requested"] == "1900-01-01")
        #expect(error["data"]?["supported"]?.arrayValue?.compactMap(\.stringValue) == MCPServer.protocolVersions)
    }

    @Test func aRequestWithoutTheRequiredMetaIsInvalidParams() async throws {
        let noCapabilities: JSONValue = ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]
        #expect(try await reply("tools/list", noCapabilities)["error"]?["code"]?.numberValue == -32602)
        let notAString: JSONValue = [
            "_meta": ["io.modelcontextprotocol/protocolVersion": 7, "io.modelcontextprotocol/clientCapabilities": [:]]
        ]
        #expect(try await reply("tools/list", notAString)["error"]?["code"]?.numberValue == -32602)
        // Discover belongs to 2026-07-28 alone, which always names its version.
        #expect(try await reply("server/discover")["error"]?["code"]?.numberValue == -32602)
    }

    @Test func modernToolCallsCarryResultTypeAndTheClientFromMeta() async throws {
        let answer = try await reply("tools/call", ["_meta": Self.modernMeta, "name": "capabilities"])
        let result = try #require(answer["result"])
        #expect(result["resultType"] == "complete")
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "jutsu")
        #expect(result["isError"] == false)
        let calls = await app.calls
        #expect(calls.count == 1)
        #expect(calls.first?.1 == "Agent CLI")
    }

    @Test func modernToolListsAreCacheable() async throws {
        let result = try #require(try await reply("tools/list", ["_meta": Self.modernMeta])["result"])
        #expect(result["ttlMs"] != nil)
        #expect(result["cacheScope"] == "public")
        #expect(result["resultType"] == "complete")
    }

    // MARK: The handshake revisions

    @Test func initializeEchoesAKnownVersionAndOffersTheNewestHandshakeOtherwise() async throws {
        for version in ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] {
            let result = try await reply("initialize", ["protocolVersion": .string(version), "capabilities": [:]])
            #expect(result["result"]?["protocolVersion"] == .string(version))
        }
        for asked: JSONValue in ["2026-07-28", "1999-01-01", 3] {
            let result = try await reply("initialize", ["protocolVersion": asked])
            #expect(result["result"]?["protocolVersion"] == "2025-11-25")
        }
        let result = try #require(try await reply("initialize", ["protocolVersion": "2025-11-25"])["result"])
        #expect(result["serverInfo"]?["name"] == "jutsu")
        #expect(result["capabilities"] == ["tools": ["listChanged": false]])
        #expect(result["instructions"]?.stringValue?.isEmpty == false)
        #expect(result["resultType"] == nil)
    }

    @Test func theHandshakeSessionNamesTheClientAndTheVersion() async throws {
        var server = server()
        _ = try await reply(
            &server, "initialize", ["protocolVersion": "2025-03-26", "clientInfo": ["name": "claude-code"]])
        #expect(await server.reply(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        #expect(try await reply(&server, "ping", id: "p")["result"] == [:])
        // 2025-03-26 has no structured output: no output schemas and no structuredContent.
        let tools = try await reply(&server, "tools/list")["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.allSatisfy { $0["outputSchema"] == nil })
        let call = try await reply(&server, "tools/call", ["name": "capabilities"])["result"]
        #expect(call?["structuredContent"] == nil)
        #expect(call?["content"]?.arrayValue?.count == 1)
        #expect(await app.calls.first?.1 == "claude-code")
    }

    // MARK: Tools

    @Test func toolsAreListedInAFixedOrderWithSchemasAndHints() async throws {
        var server = server()
        _ = try await reply(&server, "initialize", ["protocolVersion": "2025-11-25"])
        let tools = try #require(try await reply(&server, "tools/list")["result"]?["tools"]?.arrayValue)
        #expect(
            tools.map { $0["name"]?.stringValue }
                == [
                    "capabilities", "quote", "create_video", "jobs", "job_action", "create_image", "library_search",
                    "library_get", "library_download", "library_mark", "enhance", "delivery_set", "export", "frames",
                    "show",
                ])
        #expect(tools.compactMap { $0["name"]?.stringValue } == AgentCapabilities.ToolGroup.all.flatMap(\.tools))
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["inputSchema"]?["additionalProperties"] == false)
            #expect(tool["inputSchema"]?["oneOf"] == nil)
            #expect(tool["outputSchema"]?["type"] == "object")
            #expect(tool["outputSchema"]?["properties"]?["error"] != nil)
            #expect(tool["outputSchema"]?["required"] == nil)
            #expect(tool["annotations"]?["readOnlyHint"] != nil)
            #expect(tool["annotations"]?["idempotentHint"] != nil)
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            #expect(tool["title"]?.stringValue?.isEmpty == false)
        }
        let hints = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"]?.stringValue ?? "", $0["annotations"]) })
        for name in ["capabilities", "quote", "jobs", "library_search", "library_get"] {
            #expect(hints[name]??["readOnlyHint"] == true, "\(name)")
            #expect(hints[name]??["destructiveHint"] == false, "\(name)")
        }
        #expect(hints["create_video"]??["readOnlyHint"] == false)
        #expect(hints["create_video"]??["idempotentHint"] == true)
        #expect(hints["create_video"]??["destructiveHint"] == false)
        #expect(hints["job_action"]??["readOnlyHint"] == false)
        #expect(hints["job_action"]??["idempotentHint"] == false)
        for name in ["create_image", "enhance"] {
            #expect(hints[name]??["readOnlyHint"] == false, "\(name)")
            #expect(hints[name]??["idempotentHint"] == true, "\(name)")
            #expect(hints[name]??["destructiveHint"] == false, "\(name)")
        }
        #expect(hints["library_search"]??["openWorldHint"] == true)
        #expect(hints["library_download"]??["readOnlyHint"] == false)
        #expect(hints["library_download"]??["destructiveHint"] == false)
        #expect(hints["library_download"]??["idempotentHint"] == true)
        #expect(hints["library_mark"]??["idempotentHint"] == true)
        #expect(hints["library_mark"]??["destructiveHint"] == false)
        for name in ["delivery_set", "export", "frames"] {
            #expect(hints[name]??["destructiveHint"] == false, "\(name)")
        }
        #expect(hints["show"]??["readOnlyHint"] == false)
        #expect(hints["show"]??["idempotentHint"] == true)
        #expect(hints["show"]??["openWorldHint"] == false)
        let create = try #require(tools.first { $0["name"] == "create_video" })
        #expect(create["inputSchema"]?["required"] == ["request_id", "mode", "max_cost"])
        // The same list twice, byte for byte.
        let again = try #require(try await reply(&server, "tools/list")["result"]?["tools"]?.arrayValue)
        #expect(again == tools)
    }

    @Test func aToolResultIsStructuredAndTheSameJSONAsText() async throws {
        let result = try #require(try await reply("tools/call", ["name": "capabilities"])["result"])
        let structured = try #require(result["structuredContent"])
        #expect(structured["appVersion"] == "0.2.0")
        #expect(structured["connection"]?["credits"] == 1200)
        #expect(structured["budget"]?["unit"] == "credits")
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == structured)
        #expect(result["isError"] == false)
    }

    @Test func anAppErrorIsAToolErrorWithWhatToDoNext() async throws {
        await app.setAnswer(AgentResponse(error: .agentsOff))
        let result = try #require(
            try await reply("tools/call", ["name": "show", "arguments": ["page": "queue"]])["result"])
        #expect(result["isError"] == true)
        let error = try #require(result["structuredContent"]?["error"])
        #expect(error["code"] == "agents_off")
        #expect(error["retryable"] == true)
        #expect(error["next"]?.stringValue?.contains("Allow agents") == true)
        #expect(await app.calls.first?.0 == .show(.page(.queue)))
    }

    @Test func badArgumentsAreToolErrorsAndNeverReachTheApp() async throws {
        let calls: [JSONValue] = [
            ["name": "show"], ["name": "show", "arguments": ["page": "queue", "job": "x"]],
            ["name": "show", "arguments": ["page": "jobs"]], ["name": "show", "arguments": ["job": "not-a-uuid"]],
            ["name": "show", "arguments": ["page": 3]],
            ["name": "show", "arguments": ["page": "queue", "extra": true]],
            ["name": "capabilities", "arguments": ["models": "yes"]],
            ["name": "capabilities", "arguments": ["model": "../../etc"]],
        ]
        for params in calls {
            let result = try await reply("tools/call", params)["result"]
            #expect(result?["isError"] == true, "\(params)")
            #expect(result?["structuredContent"]?["error"]?["code"] == "bad_request", "\(params)")
        }
        #expect(await app.calls.isEmpty)
    }

    @Test func goodArgumentsBecomeTheirCommands() async throws {
        let job = UUID()
        _ = try await reply("tools/call", ["name": "show", "arguments": ["job": .string(job.uuidString)]])
        _ = try await reply("tools/call", ["name": "capabilities", "arguments": ["model": "seedance25"]])
        _ = try await reply("tools/call", ["name": "capabilities", "arguments": ["models": true]])
        #expect(
            await app.calls.map(\.0) == [
                .show(.job(job)), .capabilities(CapabilitiesCommand(models: true, model: "seedance25")),
                .capabilities(CapabilitiesCommand(models: true)),
            ])
    }

    // MARK: Malformed messages

    @Test func malformedCallsAreJSONRPCErrors() async throws {
        #expect(try await reply("tools/call", ["name": "delete_all"])["error"]?["code"]?.numberValue == -32602)
        #expect(try await reply("tools/call", [:])["error"]?["code"]?.numberValue == -32602)
        #expect(
            try await reply("tools/call", ["name": "show", "arguments": ["queue"]])["error"]?["code"]?.numberValue
                == -32602)
        #expect(try await reply("tools/list", ["a"])["error"]?["code"]?.numberValue == -32602)
        #expect(try await reply("resources/list")["error"]?["code"]?.numberValue == -32601)
        #expect(await app.calls.isEmpty)
    }

    @Test func linesThatArentRequestsGetTheRightAnswer() async throws {
        var server = server()
        let parse = try await reply(&server, line: Data("{oops".utf8))
        #expect(parse["error"]?["code"]?.numberValue == -32700)
        #expect(parse["id"] == .null)
        #expect(try await reply(&server, line: Data("[1,2]".utf8))["error"]?["code"]?.numberValue == -32600)
        let badID = try await reply(&server, line: Data(#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#.utf8))
        #expect(badID["error"]?["code"]?.numberValue == -32600)
        let noMethod = try await reply(&server, line: Data(#"{"jsonrpc":"2.0","id":4}"#.utf8))
        #expect(noMethod["error"]?["code"]?.numberValue == -32600)
        // Responses and notifications get no answer.
        #expect(await server.reply(to: Data(#"{"jsonrpc":"2.0","id":4,"result":{}}"#.utf8)) == nil)
        #expect(await server.reply(to: Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#.utf8)) == nil)
        // A string id comes back as it was.
        #expect(try await reply(&server, "ping", id: "abc")["id"] == "abc")
    }
}

extension FakeApp {
    func setAnswer(_ answer: AgentResponse) { self.answer = answer }
}
