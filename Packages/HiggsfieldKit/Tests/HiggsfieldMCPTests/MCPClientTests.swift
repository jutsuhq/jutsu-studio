import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

func tokenProvider(access: String = "access-1", refreshes: Locked<Int> = Locked(0)) -> TokenProvider {
    TokenProvider(
        tokens: Fixture.tokens(access: access, expiresAt: .distantFuture),
        refresh: { old in
            refreshes.update { $0 += 1 }
            return Fixture.tokens(access: "fresh", refresh: old.refreshToken, expiresAt: .distantFuture)
        },
        persist: { _ in })
}

extension Network {
    @Suite struct MCP {
        let tools = (1...5).map { tool("tool_\($0)", "Tool \($0)", ["x"]) }

        @Test func initializesOnceAndKeepsTheSession() async throws {
            let stub = mcpServer(tools: tools, pageSize: 2)
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())

            let listed = try await client.listTools()
            _ = try await client.callTool("tool_1", arguments: ["x": "y"])

            #expect(listed.map(\.name) == ["tool_1", "tool_2", "tool_3", "tool_4", "tool_5"])
            let methods = stub.requests.compactMap { $0.json?["method"]?.stringValue }
            #expect(
                methods == [
                    "initialize", "notifications/initialized", "tools/list", "tools/list", "tools/list", "tools/call",
                ])
            let initialize = try #require(stub.requests.first)
            #expect(initialize.json?["params"]?["protocolVersion"] == "2025-06-18")
            #expect(initialize.json?["params"]?["clientInfo"]?["name"] == "Jutsu Studio")
            #expect(initialize.header("Mcp-Session-Id") == nil)
            for request in stub.requests {
                #expect(request.method == "POST")
                #expect(request.header("Authorization") == "Bearer access-1")
                #expect(request.header("Accept") == "application/json, text/event-stream")
            }
            for request in stub.requests.dropFirst() {
                #expect(request.header("Mcp-Session-Id") == "session-1")
                #expect(request.header("MCP-Protocol-Version") == "2025-06-18")
            }
            #expect(stub.requests[3].json?["params"]?["cursor"] == "2")
            #expect(stub.requests[5].json?["params"]?["arguments"] == ["x": "y"])
        }

        @Test func readsToolResultsFromAnEventStream() async throws {
            let stub = mcpServer(tools: tools) { name, arguments in ["tool": .string(name), "echo": arguments] }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            let result = try await client.callTool("tool_2", arguments: ["a": 1])
            #expect(result.value == ["tool": "tool_2", "echo": ["a": 1]])
            #expect(result.text == "done")
        }

        @Test func unauthorizedRefreshesOnceAndRetries() async throws {
            let refreshes = Locked(0)
            let stub = mcpServer(tools: tools, rejected: ["stale"])
            let client = MCPClient(
                endpoint: Fixture.mcpURL, tokens: tokenProvider(access: "stale", refreshes: refreshes),
                session: stub.session())

            #expect(try await client.listTools().count == 5)
            #expect(refreshes.value == 1)
            #expect(stub.requests.map { $0.header("Authorization") ?? "" }.first == "Bearer stale")
            #expect(stub.requests.dropFirst().allSatisfy { $0.header("Authorization") == "Bearer fresh" })
        }

        @Test func secondUnauthorizedIsReported() async throws {
            let stub = mcpServer(tools: tools, rejected: ["stale", "fresh"])
            let client = MCPClient(
                endpoint: Fixture.mcpURL, tokens: tokenProvider(access: "stale"), session: stub.session())
            await #expect(throws: HiggsfieldError.unauthorized) { try await client.listTools() }
        }

        @Test func failedHandshakeIsRetriedWithoutItsSessionID() async throws {
            let answering = mcpServer(tools: tools)
            let failed = Locked(false)
            let stub = StubServer { request, _ in
                if request.json?["method"] == "notifications/initialized",
                    failed.update({ value in
                        let first = !value; value = true; return first
                    })
                {
                    return StubResponse(status: 500)
                }
                if request.json?["method"] == "initialize", request.header("Mcp-Session-Id") != nil {
                    return StubResponse(status: 400)
                }
                return answering.respond(to: request)
            }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            await #expect(throws: HiggsfieldError.server(status: 500)) { try await client.listTools() }
            #expect(try await client.listTools().count == 5)
            #expect(
                stub.requests.filter { $0.json?["method"] == "initialize" }.allSatisfy {
                    $0.header("Mcp-Session-Id") == nil
                })
        }

        @Test func statelessRequestsCarryTheNegotiatedVersion() async throws {
            let answering = mcpServer(tools: tools)
            let stub = StubServer { request, _ in
                var response = answering.respond(to: request)
                response.headers.removeValue(forKey: "Mcp-Session-Id")
                return response
            }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            #expect(try await client.listTools().count == 5)
            #expect(
                stub.requests.dropFirst().allSatisfy {
                    $0.header("MCP-Protocol-Version") == "2025-06-18" && $0.header("Mcp-Session-Id") == nil
                })
        }

        @Test func incompatibleInitializeResultStopsBeforeToolsAreCalled() async throws {
            let answering = mcpServer(tools: tools)
            let stub = StubServer { request, _ in
                guard request.json?["method"] == "initialize", let id = request.json?["id"] else {
                    return answering.respond(to: request)
                }
                return .json(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": "2099-01-01"]])
            }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            await #expect(throws: HiggsfieldError.server(status: 200)) { try await client.listTools() }
            #expect(stub.requests.count == 1)
        }

        /// `mcpServer` with a new session ID per `initialize`, answering `404` to any session in `expired`.
        private func sessionServer(expired: Locked<Set<String>>) -> StubServer {
            let answering = mcpServer(tools: tools)
            let sessions = Locked(0)
            return StubServer { request, _ in
                if request.json?["method"] == "initialize" {
                    let number = sessions.update { count -> Int in
                        count += 1
                        return count
                    }
                    var response = answering.respond(to: request)
                    response.headers["Mcp-Session-Id"] = "session-\(number)"
                    return response
                }
                if let session = request.header("Mcp-Session-Id"), expired.value.contains(session) {
                    return .notFound
                }
                return answering.respond(to: request)
            }
        }

        @Test func expiredSessionIsStartedAgainAndTheCallRetried() async throws {
            let expired = Locked<Set<String>>([])
            let stub = sessionServer(expired: expired)
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            #expect(try await client.listTools().count == 5)

            expired.update { $0 = ["session-1"] }
            let result = try await client.callTool("tool_1", arguments: [:])

            #expect(result.text == "done")
            let methods = stub.requests.compactMap { $0.json?["method"]?.stringValue }
            #expect(
                methods == [
                    "initialize", "notifications/initialized", "tools/list", "tools/call", "initialize",
                    "notifications/initialized", "tools/call",
                ])
            #expect(stub.requests[4].header("Mcp-Session-Id") == nil)
            #expect(stub.requests[5].header("Mcp-Session-Id") == "session-2")
            #expect(stub.requests[6].header("Mcp-Session-Id") == "session-2")
        }

        @Test func secondExpiredSessionIsReported() async throws {
            let expired = Locked<Set<String>>(["session-1", "session-2", "session-3"])
            let stub = sessionServer(expired: expired)
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            await #expect(throws: HiggsfieldError.server(status: 404)) { try await client.listTools() }
            #expect(stub.requests.filter { $0.json?["method"] == "initialize" }.count == 2)
        }

        @Test func notFoundWithoutASessionIsAServerError() async throws {
            let stub = StubServer { _, _ in .notFound }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            await #expect(throws: HiggsfieldError.server(status: 404)) { try await client.listTools() }
            #expect(stub.requests.count == 1)
        }

        @Test func replyAfterManyNotificationsIsFound() async throws {
            let answering = mcpServer(tools: tools)
            let stub = StubServer { request, _ in
                var response = answering.respond(to: request)
                guard request.json?["method"] == "tools/list" else { return response }
                let progress = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#
                response.body = String(repeating: "event: message\ndata: \(progress)\n\n", count: 5_000) + response.body
                return response
            }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            #expect(try await client.listTools().count == 5)
        }

        @Test func malformedToolIsLeftOut() async throws {
            let stub = mcpServer(tools: [tools[0], ["name": "no_schema"], ["description": "no name"], tools[1]])
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            #expect(try await client.listTools().map(\.name) == ["tool_1", "tool_2"])
        }

        @Test func jsonRPCErrorsAreThrown() async throws {
            let stub = StubServer { request, _ in
                guard let id = request.json?["id"] else { return StubResponse(status: 202) }
                return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            await #expect(throws: JSONRPCError(code: -32601, message: "Method not found")) {
                try await client.listTools()
            }
        }

        @Test func toolPagingStopsOnARepeatedCursor() async throws {
            let stub = pagingServer { _ in "again" }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            #expect(try await client.listTools().count == 2)
            #expect(stub.requests.filter { $0.json?["method"] == "tools/list" }.count == 2)
        }

        @Test func toolPagingStopsAfterTheMaximumPageCount() async throws {
            let stub = pagingServer { page in String(page + 1) }
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session())
            #expect(try await client.listTools().count == MCPClient.maxToolPages)
        }

        /// A server whose every `tools/list` page holds one tool and points to `next(page)`.
        private func pagingServer(next: @escaping @Sendable (Int) -> String) -> StubServer {
            StubServer { request, _ in
                guard let id = request.json?["id"] else { return StubResponse(status: 202) }
                guard request.json?["method"] == "tools/list" else {
                    return .json(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": "2025-06-18"]])
                }
                let page = Int(request.json?["params"]?["cursor"]?.stringValue ?? "0") ?? 0
                let result: JSONValue = [
                    "tools": [tool("tool_\(page)", "Tool", [])], "nextCursor": .string(next(page)),
                ]
                return .json(["jsonrpc": "2.0", "id": id, "result": result])
            }
        }

        @Test func aReplyThatNeverComesTimesOut() async throws {
            let answering = mcpServer(tools: tools)
            let stub = StubServer { request, _ in
                guard request.json?["method"]?.stringValue == "tools/call" else {
                    return answering.respond(to: request)
                }
                // Keep-alive comments only: data keeps coming, the reply never does.
                return StubResponse(
                    headers: ["Content-Type": "text/event-stream"], body: ": ping\n\n", keepsOpen: true)
            }
            let client = MCPClient(
                endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: stub.session(), requestTimeout: 0.3)
            await #expect(throws: HiggsfieldError.network) { try await client.callTool("tool_1", arguments: [:]) }
        }

        @Test func refreshGrantKeepsTheOldRefreshTokenWhenNoneIsIssued() async throws {
            let stub = StubServer { _, _ in .json(#"{"access_token":"next","expires_in":60}"#) }
            let now = Date(timeIntervalSince1970: 500)
            let client = Fixture.client(try Fixture.server(Fixture.clerkMetadata), session: stub.session(), now: now)
            let refreshed = try await client.refresh(Fixture.tokens(expiresAt: now))
            #expect(refreshed.accessToken == "next")
            #expect(refreshed.refreshToken == "refresh-1")
            #expect(refreshed.expiresAt == now + 60)
            let form = try #require(stub.requests.first).form
            #expect(form["grant_type"] == "refresh_token")
            #expect(form["refresh_token"] == "refresh-1")
            #expect(form["client_id"] == "client-1")
            #expect(form["resource"] == "https://mcp.higgsfield.ai/mcp")
        }
    }
}
