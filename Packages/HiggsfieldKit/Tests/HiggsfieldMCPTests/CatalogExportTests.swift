import Foundation
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

extension Network {
    @Suite struct CatalogExport {
        /// A tool with every field `tools/list` may carry, which `MCPTool` doesn't decode.
        static let described: JSONValue = [
            "name": "job_status", "title": "Job status", "description": "Check a job",
            "annotations": ["readOnlyHint": true],
            "inputSchema": ["type": "object", "properties": ["jobId": ["type": "string"]]],
            "outputSchema": ["type": "object", "properties": ["generation": ["type": "object"]]],
        ]
        static let explore = tool("models_explore", "Explore models", ["action", "type", "model_id", "after", "limit"])
        static let date = Date(timeIntervalSince1970: 1_791_000_000)

        static func account(
            tools: [JSONValue], call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        ) -> (HiggsfieldAccount, StubServer) {
            let stub = mcpServer(tools: tools, pageSize: 2, call: call)
            let session = stub.session()
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: session)
            return (HiggsfieldAccount(client: client, session: session, now: { date }), stub)
        }

        static func decode(_ data: Data) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: data)
        }

        static let unlim: JSONValue = ["available": false, "expires_at": .null, "remaining": .null]

        /// Video models come in two pages; the others in one. Answers carry the account's `unlim` block, as in the
        /// catalog snapshot of 2026-10-15.
        static func answer(_ name: String, _ arguments: JSONValue) -> JSONValue {
            switch (arguments["action"]?.stringValue, arguments["type"]?.stringValue, arguments["after"]) {
            case ("list", "video", nil):
                ["items": [["id": "seedance_2_5"]], "has_more": true, "next_page_token": "100", "unlim": unlim]
            case ("list", "video", _):
                ["items": [["id": "kling3_0_motion_control"]], "has_more": false, "unlim": unlim]
            case ("list", let type?, _): ["items": [["id": .string("\(type)-model")]], "has_more": false]
            default: ["id": arguments["model_id"] ?? .null, "supports_unlim": true, "unlim": unlim]
            }
        }

        @Test func exportsTheRawToolsAndExploresTheModels() async throws {
            let tools = [Self.described, tool("balance", "Credits", []), Self.explore]
            let (account, stub) = Self.account(tools: tools, call: Self.answer)

            let export = try Self.decode(try await account.exportCatalog())

            #expect(export["tools"] == .array(tools))
            #expect(Account.listings(stub) == 2)
            #expect(export["exportedAt"] == .string(ISO8601DateFormatter().string(from: Self.date)))
            let lists = export["models"]?["list"]
            #expect(lists?["video"]?.arrayValue?.count == 2)
            #expect(
                lists?["video"]?.arrayValue?.compactMap { $0["arguments"] } == [
                    ["action": "list", "type": "video", "limit": 100],
                    ["action": "list", "type": "video", "limit": 100, "after": "100"],
                ])
            #expect(lists?["image"]?.arrayValue?.first?["structuredContent"]?["items"] == [["id": "image-model"]])
            #expect(lists?["audio"]?.arrayValue?.count == 1)
            let gets = export["models"]?["get"]?.objectValue ?? [:]
            // Every listed video and image model is described; audio models aren't.
            #expect(Set(gets.keys) == ["seedance_2_5", "kling3_0_motion_control", "image-model"])
            #expect(gets["seedance_2_5"]?["structuredContent"]?["unlim"] == Self.unlim)
            #expect(gets["seedance_2_5"]?["structuredContent"]?["supports_unlim"] == true)
            #expect(Account.calls(stub).allSatisfy { $0["name"] == "models_explore" })
        }

        @Test func theExportIsPrettyAndKeySorted() async throws {
            let (account, _) = Self.account(tools: [Self.explore], call: Self.answer)
            let text = String(decoding: try await account.exportCatalog(), as: UTF8.self)
            #expect(text.hasPrefix("{\n  \"exportedAt\""))
            #expect(text.contains("\"models\" : {"))
        }

        @Test func noTokenSessionOrEmailIsExported() async throws {
            let (account, stub) = Self.account(tools: [Self.described, Self.explore]) { name, arguments in
                var answer = Self.answer(name, arguments)
                if case .object(var object) = answer {
                    object["owner"] = "me@example.com"
                    answer = .object(object)
                }
                return answer
            }

            let text = String(decoding: try await account.exportCatalog(redacting: ["me@example.com"]), as: UTF8.self)

            #expect(stub.requests.contains { $0.header("Mcp-Session-Id") == "session-1" })
            for secret in ["access-1", "refresh-1", "session-1", "client-1", "me@example.com", "Bearer"] {
                #expect(!text.contains(secret), "\(secret) is in the export")
            }
            #expect(text.contains("<redacted>"))
        }

        @Test func aServerWithoutModelsExploreStillExportsItsTools() async throws {
            let (account, stub) = Self.account(tools: [Self.described])

            let export = try Self.decode(try await account.exportCatalog())

            #expect(export["tools"] == [Self.described])
            #expect(export["models"] == .null)
            #expect(Account.calls(stub).isEmpty)
        }
    }
}
