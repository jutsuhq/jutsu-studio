import Foundation
import HiggsfieldCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(os)
    import os

    private let logger = Logger(subsystem: "com.jutsustudio", category: "MCPClient")
#endif

/// The three MCP calls this app needs (`initialize`, `tools/list`, `tools/call`) as JSON-RPC 2.0 over
/// Streamable HTTP, with a bearer token. Initializes lazily on the first call, and again after the server
/// ended the session.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"
    /// `tools/list` stops after this many pages, so a server that never ends its cursor chain can't loop.
    static let maxToolPages = 50

    private let endpoint: URL
    private let session: URLSession
    private let tokens: TokenProvider
    private var activeSession: MCPSession?
    private var nextID = 1
    private var initialization: Task<MCPSession, any Error>?
    /// Seconds one request may take in all, so a stream that never answers can't hold its job in the queue.
    /// A submit needs a few seconds.
    private let requestTimeout: TimeInterval

    public init(endpoint: URL, tokens: TokenProvider, session: URLSession = .shared, requestTimeout: TimeInterval = 120)
    {
        self.endpoint = endpoint
        self.tokens = tokens
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// A tool that doesn't decode (no `inputSchema`, say) is left out, so it can't hide the others.
    public func listTools() async throws -> [MCPTool] {
        try await listToolValues().compactMap { value in
            guard let tool = try? value.decode(MCPTool.self) else {
                #if canImport(os)
                    let toolName = value["name"]?.stringValue ?? "unnamed"
                    logger.error("Skipped the malformed tool \(toolName, privacy: .public) of tools/list")
                #endif
                return nil
            }
            return tool
        }
    }

    /// Every page of `tools/list`, each tool exactly as the server described it.
    public func listToolValues() async throws -> [JSONValue] {
        struct Page: Decodable {
            let tools: [JSONValue]
            let nextCursor: String?
        }
        var tools: [JSONValue] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        for _ in 0..<Self.maxToolPages {
            let params = cursor.map { JSONValue.object(["cursor": .string($0)]) }
            let page = try await call("tools/list", params: params).decode(Page.self)
            tools += page.tools
            guard let next = page.nextCursor, seenCursors.insert(next).inserted else { break }
            cursor = next
        }
        return tools
    }

    public func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        try await call("tools/call", params: ["name": .string(name), "arguments": .object(arguments)])
            .decode(MCPToolResult.self)
    }

    /// Streamable HTTP: a `404` to a request with a session ID means the server ended that session, and did
    /// not process the request. The client starts a new session, without the old ID, and sends the request once more.
    private func call(_ method: String, params: JSONValue?) async throws -> JSONValue {
        do {
            return try await callInSession(method, params: params)
        } catch let expired as SessionExpired {
            endSession(expired.id)
        }
        do {
            return try await callInSession(method, params: params)
        } catch let expired as SessionExpired {
            endSession(expired.id)
            throw HiggsfieldError.server(status: 404)
        }
    }

    /// Opens the session and reads a token, so a call that follows fails before that point only by its own request.
    func prepare() async throws {
        _ = try await initialize()
        _ = try await tokens.accessToken()
    }

    private func callInSession(_ method: String, params: JSONValue?) async throws -> JSONValue {
        let current = try await initialize()
        return try await request(method, params: params, in: current).value
    }

    /// Forgets session `id`, unless a concurrent call already did and started the next one.
    private func endSession(_ id: String) {
        guard activeSession?.id == id else { return }
        activeSession = nil
        initialization = nil
    }

    private func initialize() async throws -> MCPSession {
        if let activeSession { return activeSession }
        if let initialization { return try await initialization.value }
        let task = Task {
            let (value, response) = try await request(
                "initialize",
                params: [
                    "protocolVersion": .string(Self.protocolVersion),
                    "capabilities": [:],
                    "clientInfo": ["name": "Jutsu Studio", "version": "0.1.0"],
                ], in: nil)
            guard value["protocolVersion"]?.stringValue == Self.protocolVersion else {
                throw HiggsfieldError.server(status: response.statusCode)
            }
            let current = MCPSession(id: response.value(forHTTPHeaderField: "Mcp-Session-Id"))
            _ = try await post(RPCMessage(id: nil, method: "notifications/initialized", params: nil), in: current)
            activeSession = current
            return current
        }
        initialization = task
        defer { if initialization == task { initialization = nil } }
        return try await task.value
    }

    private func request(
        _ method: String, params: JSONValue?, in current: MCPSession?
    ) async throws
        -> (value: JSONValue, response: HTTPURLResponse)
    {
        let id = nextID
        nextID += 1
        let (data, response) = try await post(
            RPCMessage(id: id, method: method, params: params), in: current, until: Self.isReply(to: id))
        let isEventStream = response.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true
        let messages =
            isEventStream ? serverSentEventData(String(decoding: data, as: UTF8.self)).map { Data($0.utf8) } : [data]
        let decoder = JSONDecoder()
        // An event stream may carry server notifications before the response; skip anything else.
        guard
            let reply = messages.lazy.compactMap({ try? decoder.decode(RPCReply.self, from: $0) }).first(where: {
                $0.id == id
            })
        else { throw HiggsfieldError.server(status: response.statusCode) }
        if let error = reply.error { throw error }
        return (reply.result ?? .null, response)
    }

    /// Whether the event stream read so far ends with the reply to `id`. The reader asks after every event, so
    /// only the newest one is decoded: each event once, however long the stream.
    static func isReply(to id: Int) -> @Sendable ([String]) -> Bool {
        { events in
            events.last.flatMap { try? JSONDecoder().decode(RPCReply.self, from: Data($0.utf8)) }?.id == id
        }
    }

    /// POSTs one message with the bearer token; on `401` refreshes once and retries. An event-stream
    /// answer is read until `isComplete` sees the reply, not until the server closes the stream.
    private func post(
        _ message: RPCMessage, in current: MCPSession?,
        until isComplete: @escaping @Sendable ([String]) -> Bool = { _ in false }
    ) async throws -> (Data, HTTPURLResponse) {
        var token = try await tokens.accessToken()
        for attempt in 1...2 {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let current {
                request.setValue(current.id, forHTTPHeaderField: "Mcp-Session-Id")
                request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            }
            request.httpBody = try JSONEncoder().encode(message)
            let (data, response) = try await session.send(request, within: requestTimeout, until: isComplete)
            if response.statusCode == 401, attempt == 1 {
                token = try await tokens.accessToken(replacing: token)
                continue
            }
            if response.statusCode == 404, let id = current?.id { throw SessionExpired(id: id) }
            switch response.statusCode {
            case 200..<300: return (data, response)
            case 401, 403: throw HiggsfieldError.unauthorized
            default: throw HiggsfieldError.server(status: response.statusCode)
            }
        }
        throw HiggsfieldError.unauthorized
    }
}

/// Published only after both initialization messages succeed. A server may be stateless.
private struct MCPSession: Sendable {
    let id: String?
}

/// A JSON-RPC 2.0 error object, thrown as is.
public struct JSONRPCError: Error, Decodable, Sendable, Hashable {
    public var code: Int
    public var message: String
}

/// The server answered `404` to a request with session `id`.
private struct SessionExpired: Error {
    let id: String
}

private struct RPCMessage: Encodable {
    let jsonrpc = "2.0"
    /// `nil` for a notification.
    let id: Int?
    let method: String
    let params: JSONValue?
}

private struct RPCReply: Decodable {
    let id: Int?
    let result: JSONValue?
    let error: JSONRPCError?
}
