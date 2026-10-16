import Foundation
import HiggsfieldMCP

extension RecordedRequest {
    public var form: [String: String] {
        var result: [String: String] = [:]
        for pair in (bodyText ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    public var json: JSONValue? { body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
}

extension StubResponse {
    public static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        .json(
            String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self), status: status,
            headers: headers)
    }
}

/// The `WWW-Authenticate` of the stub's `401`, shaped like the real server's. A bare `Bearer` crashes
/// swift-corelibs-foundation's challenge parser on Linux (`_StringGuts.validateScalarIndex`).
public let defaultBearerChallenge =
    #"Bearer resource_metadata="https://mcp.higgsfield.ai/.well-known/oauth-protected-resource/mcp""#

/// A Streamable HTTP MCP server: JSON for `initialize`, SSE for everything else, a session ID,
/// and `401` for any bearer token in `rejected`. `call` answers `tools/call` with structured content.
public func mcpServer(
    tools: [JSONValue], pageSize: Int = 100, rejected: Set<String> = [],
    wwwAuthenticate: String = defaultBearerChallenge,
    call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
) -> StubServer {
    mcpServer(tools: { tools }, pageSize: pageSize, rejected: rejected, wwwAuthenticate: wwwAuthenticate, call: call)
}

/// The same server with a tool list that may change: `tools` is read again for every `tools/list` page.
public func mcpServer(
    tools currentTools: @escaping @Sendable () -> [JSONValue], pageSize: Int = 100, rejected: Set<String> = [],
    wwwAuthenticate: String = defaultBearerChallenge,
    call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
) -> StubServer {
    StubServer { request, _ in
        if rejected.contains(String(request.header("Authorization")?.dropFirst("Bearer ".count) ?? "")) {
            return StubResponse(status: 401, headers: ["WWW-Authenticate": wwwAuthenticate])
        }
        guard let message = request.json, let method = message["method"]?.stringValue else { return .notFound }
        guard let id = message["id"] else { return StubResponse(status: 202) }
        let result: JSONValue
        switch method {
        case "initialize":
            let reply: JSONValue = [
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "stub"],
                ],
            ]
            return .json(reply, headers: ["Mcp-Session-Id": "session-1"])
        case "tools/list":
            let tools = currentTools()
            let start = Int(message["params"]?["cursor"]?.stringValue ?? "0") ?? 0
            let end = min(start + pageSize, tools.count)
            var page: [String: JSONValue] = ["tools": .array(Array(tools[start..<end]))]
            if end < tools.count { page["nextCursor"] = .string(String(end)) }
            result = .object(page)
        case "tools/call":
            let name = message["params"]?["name"]?.stringValue ?? ""
            let structured = call(name, message["params"]?["arguments"] ?? [:])
            result = ["content": [["type": "text", "text": "done"]], "structuredContent": structured]
        default:
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
        let reply = String(
            decoding: (try? JSONEncoder().encode(["jsonrpc": "2.0", "id": id, "result": result] as JSONValue))
                ?? Data(), as: UTF8.self)
        let progress = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#
        return .eventStream("event: message\ndata: \(progress)\n\nevent: message\ndata: \(reply)\n\n")
    }
}

public func tool(_ name: String, _ description: String, _ properties: [String]) -> JSONValue {
    [
        "name": .string(name), "description": .string(description),
        "inputSchema": [
            "type": "object",
            "properties": .object(Dictionary(uniqueKeysWithValues: properties.map { ($0, ["type": "string"]) })),
        ],
    ]
}

/// A tool whose one input is a `params` object with `keys`, as the operations on a result take theirs.
public func paramsTool(_ name: String, _ keys: [String]) -> JSONValue {
    [
        "name": .string(name), "description": "Works on an existing video",
        "inputSchema": [
            "type": "object", "required": ["params"],
            "properties": [
                "params": [
                    "type": "object",
                    "properties": .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, ["type": "string"]) })),
                ]
            ],
        ],
    ]
}
