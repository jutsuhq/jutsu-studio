import Foundation
import HiggsfieldMCP
import JutsuAgent

/// The Model Context Protocol over stdio, written out by hand: JSON-RPC 2.0, one message per line, and only what an
/// agent needs to drive the app. It speaks both eras of the protocol, chosen per request:
///
/// - **2026-07-28** is stateless: a request carries its protocol version, the client's capabilities and identity in
///   `params._meta` under `io.modelcontextprotocol/…`, `server/discover` describes the server, and every result says
///   `resultType: "complete"` and names the server in its own `_meta`.
/// - **2025-11-25 and earlier** start with `initialize` (then `notifications/initialized`, and `ping` at any time),
///   which fixes the version and the client for the rest of the process. Claude Code still speaks this one.
///
/// Every tool is one `AgentCommand` passed through to the app; `send` makes the round trip and turns a failure to
/// reach the app into an `AgentError`, which the model sees as a tool error. A malformed call (not JSON-RPC, an
/// unknown method or tool, params of the wrong shape) is a JSON-RPC error instead.
public struct MCPServer {
    /// Newest first. Requests with per-request `_meta` may name any of them; `initialize` negotiates one of the last
    /// four, the handshake revisions.
    public static let protocolVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let handshakeVersions = Array(protocolVersions.dropFirst())

    public typealias Send = @Sendable (AgentCommand, _ client: String?) async -> AgentResponse
    /// Hands the agent's file at `path` to the app for `request` and returns its path in the app's inbox.
    public typealias Stage =
        @Sendable (_ path: String, UploadRequest, _ client: String?) async -> Result<
            String, AgentError
        >

    let version: String
    let send: Send
    let stage: Stage
    /// Set by `initialize`: the negotiated version and the client's name, for the requests without `_meta` after it.
    private var session: (version: String, client: String?)?

    public init(
        version: String,
        stage: @escaping Stage = { path, _, _ in
            .failure(AgentError(.fileRefused, message: "This helper can't send \(path).", retryable: false))
        },
        send: @escaping Send
    ) {
        self.version = version
        self.stage = stage
        self.send = send
    }

    /// The reply to one line from the client; nil for a notification or a response, which get none.
    public mutating func reply(to line: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return Self.encode(error: .parseError, "Parse error: not JSON.", id: .null)
        }
        guard case .object(let object) = message else {
            // Batches were dropped from the protocol in 2025-06-18, and no client sends them over stdio.
            return Self.encode(error: .invalidRequest, "Invalid request: expected one JSON-RPC object.", id: .null)
        }
        guard let method = object["method"] else {
            // A response to a request of ours; this server sends none.
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.encode(error: .invalidRequest, "Invalid request: no method.", id: object["id"] ?? .null)
        }
        // A notification (`notifications/initialized`, `notifications/cancelled`) has no id and gets no answer.
        guard let id = object["id"] else { return nil }
        guard Self.isValidID(id) else {
            return Self.encode(error: .invalidRequest, "Invalid request: id is a string or an integer.", id: .null)
        }
        guard case .string(let name) = method else {
            return Self.encode(error: .invalidRequest, "Invalid request: method is a string.", id: id)
        }
        let params: [String: JSONValue]
        switch object["params"] {
        case nil, .null?: params = [:]
        case .object(let value)?: params = value
        default: return Self.encode(error: .invalidParams, "Invalid params: expected an object.", id: id)
        }
        if name == "initialize" { return initialize(params, id: id) }
        switch Era.of(params) {
        case .failure(let error): return Self.encode(error, id: id)
        case .success(let era): return await respond(to: name, params: params, era: era, id: id)
        }
    }

    // MARK: Eras

    /// How one request is served: by the version its `_meta` names, or by the session `initialize` set up.
    enum Era {
        case perRequest(version: String, client: String?)
        case session

        /// A request whose `_meta` names a protocol version must name a supported one and carry the client's
        /// capabilities; without one it belongs to the handshake era.
        static func of(_ params: [String: JSONValue]) -> Result<Era, RPCError> {
            let meta = params["_meta"]?.objectValue ?? [:]
            guard let requested = meta[MetaKey.protocolVersion] else { return .success(.session) }
            guard case .string(let version) = requested else {
                return .failure(RPCError(.invalidParams, "Invalid params: \(MetaKey.protocolVersion) is a string."))
            }
            guard protocolVersions.contains(version) else {
                return .failure(
                    RPCError(
                        .unsupportedProtocolVersion, "Unsupported protocol version",
                        data: [
                            "supported": .array(protocolVersions.map { .string($0) }),
                            "requested": .string(String(version.prefix(64))),
                        ]))
            }
            guard case .object = meta[MetaKey.clientCapabilities] else {
                return .failure(
                    RPCError(.invalidParams, "Invalid params: _meta needs \(MetaKey.clientCapabilities), an object."))
            }
            return .success(.perRequest(version: version, client: clientName(meta[MetaKey.clientInfo])))
        }
    }

    enum MetaKey {
        static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        static let clientInfo = "io.modelcontextprotocol/clientInfo"
        static let serverInfo = "io.modelcontextprotocol/serverInfo"
    }

    private func respond(to method: String, params: [String: JSONValue], era: Era, id: JSONValue) async -> Data? {
        let (version, client): (String, String?) =
            switch era {
            case .perRequest(let version, let client): (version, client)
            // Clients that skip the handshake get its newest revision.
            case .session: (session?.version ?? Self.handshakeVersions[0], session?.client)
            }
        let result: Result<JSONValue, RPCError>
        switch method {
        case "server/discover":
            guard case .perRequest = era else {
                return Self.encode(
                    error: .invalidParams,
                    "Invalid params: server/discover needs _meta with \(MetaKey.protocolVersion).",
                    id: id)
            }
            result = .success(discovery)
        case "ping": result = .success([:])
        case "tools/list": result = .success(toolList(version: version, era: era))
        case "tools/call": result = await call(params, version: version, client: client)
        default: result = .failure(RPCError(.methodNotFound, "Method not found: \(method.prefix(64))."))
        }
        switch result {
        case .failure(let error): return Self.encode(error, id: id)
        case .success(var value):
            if case .perRequest = era { value = completed(value) }
            return Self.encode(result: value, id: id)
        }
    }

    /// The handshake. A version this server speaks is echoed; any other gets the newest handshake revision, and the
    /// client decides whether it can go on.
    private mutating func initialize(_ params: [String: JSONValue], id: JSONValue) -> Data? {
        let requested = params["protocolVersion"]?.stringValue
        let negotiated =
            requested.flatMap { Self.handshakeVersions.contains($0) ? $0 : nil } ?? Self.handshakeVersions[0]
        session = (negotiated, Self.clientName(params["clientInfo"]))
        return Self.encode(
            result: [
                "protocolVersion": .string(negotiated),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": serverInfo,
                "instructions": .string(Self.instructions),
            ], id: id)
    }

    // MARK: Results

    private var serverInfo: JSONValue {
        ["name": "jutsu", "title": "Jutsu Studio", "version": .string(version)]
    }

    private var discovery: JSONValue {
        [
            "supportedVersions": .array(Self.protocolVersions.map { .string($0) }),
            "capabilities": ["tools": ["listChanged": false]],
            "instructions": .string(Self.instructions),
            // The same for every client and fixed for this binary, which is replaced with the app.
            "ttlMs": .number(Double(Self.cacheMilliseconds)), "cacheScope": "public",
        ]
    }

    private func toolList(version: String, era: Era) -> JSONValue {
        var list: JSONValue = [
            "tools": .array(Tool.allCases.map { $0.definition(structured: Self.isStructured(version)) })
        ]
        if case .perRequest = era, case .object(var fields) = list {
            fields["ttlMs"] = .number(Double(Self.cacheMilliseconds))
            fields["cacheScope"] = "public"
            list = .object(fields)
        }
        return list
    }

    static let cacheMilliseconds = 3_600_000

    /// Adds what 2026-07-28 asks of every result: `resultType`, and the server's name in `_meta`.
    private func completed(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        fields["resultType"] = "complete"
        var meta = fields["_meta"]?.objectValue ?? [:]
        meta[MetaKey.serverInfo] = serverInfo
        fields["_meta"] = .object(meta)
        return .object(fields)
    }

    private func call(
        _ params: [String: JSONValue], version: String, client: String?
    ) async -> Result<
        JSONValue, RPCError
    > {
        guard case .string(let name)? = params["name"] else {
            return .failure(RPCError(.invalidParams, "Invalid params: tools/call needs name, a string."))
        }
        guard let tool = Tool(rawValue: name) else {
            return .failure(RPCError(.invalidParams, "Unknown tool '\(name.prefix(64))'."))
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let value)?: arguments = value
        default: return .failure(RPCError(.invalidParams, "Invalid params: arguments is an object."))
        }
        let response: AgentResponse
        switch tool.command(arguments) {
        case .success(.createVideo(let command)): response = await createVideo(command, client: client)
        case .success(.createImage(let command)): response = await createImage(command, client: client)
        case .success(let command): response = await send(command, client)
        case .failure(let error): response = AgentResponse(error: error)
        }
        return .success(Self.toolResult(response, structured: Self.isStructured(version)))
    }

    /// Hands the request's files to the app, each checked against the request ID before a byte is sent, then sends the
    /// command naming their copies. A request the app already queued with these parameters (`request_known`) needs no
    /// file again: the command goes without them and gets the jobs it queued before.
    private func createVideo(_ command: CreateVideoCommand, client: String?) async -> AgentResponse {
        let request = UploadRequest(
            command: "create_video", requestID: command.requestID, fingerprint: command.fingerprint)
        var staged = command
        do throws(AgentError) {
            if let path = command.video.source?.path {
                staged.video.source?.path = try await stage(path, request, client).get()
            }
            staged.video.images = []
            for path in command.video.images {
                staged.video.images.append(try await stage(path, request, client).get())
            }
        } catch  where error.code == .requestKnown {
            staged.video.source?.path = nil
            staged.video.images = []
        } catch {
            return AgentResponse(error: error)
        }
        return await send(.createVideo(staged), client)
    }

    /// `create_image` likewise: its input is handed over first, unless the app already took the request.
    private func createImage(_ command: CreateImageCommand, client: String?) async -> AgentResponse {
        let request = UploadRequest(
            command: "create_image", requestID: command.requestID, fingerprint: command.fingerprint)
        var staged = command
        do throws(AgentError) {
            if let path = command.image.input { staged.image.input = try await stage(path, request, client).get() }
        } catch  where error.code == .requestKnown {
            staged.image.input = nil
        } catch {
            return AgentResponse(error: error)
        }
        return await send(.createImage(staged), client)
    }
}

// Tool results, names and encoding.
extension MCPServer {
    /// The app's answer as tool output: its JSON as text for every client, and as structured content for those that
    /// read it. A success is the result itself (the capabilities, what `show` opened); a failure is
    /// `{"error": {code, message, retryable, next}}` with `isError`, so the model sees what to do next.
    static func toolResult(_ response: AgentResponse, structured: Bool) -> JSONValue {
        let answer = response.error.map { ["error": encoded($0)] } ?? success(response)
        let text = (try? AgentWire.line(answer)).map { String(decoding: $0.dropLast(), as: UTF8.self) } ?? "{}"
        var result: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(answer["error"] != nil),
        ]
        if structured { result["structuredContent"] = answer }
        return .object(result)
    }

    /// The one answer a successful response carries, else `lost_answer`.
    private static func success(_ response: AgentResponse) -> JSONValue {
        let answers: [(any Encodable)?] = [
            response.capabilities, response.shown, response.quote, response.created, response.jobs, response.acted,
            response.library, response.marked, response.delivery, response.exported,
        ]
        guard let answer = answers.lazy.compactMap(\.self).first else {
            return ["error": encoded(AgentError.lostAnswer)]
        }
        return encoded(answer)
    }

    private static func encoded(_ value: some Encodable) -> JSONValue {
        (try? AgentWire.line(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? [:]
    }

    /// Structured tool output and output schemas exist from 2025-06-18 on; the dates sort as strings.
    static func isStructured(_ version: String) -> Bool { version >= "2025-06-18" }

    /// The client's `title`, else its `name`, cut to 64 characters: shown to the person as where a job came from.
    static func clientName(_ info: JSONValue?) -> String? {
        (info?["title"]?.stringValue ?? info?["name"]?.stringValue)
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .integer, .unsignedInteger: true
        case .number(let value): value.rounded() == value && value.isFinite
        default: false
        }
    }

    static let instructions = """
        Drives the Jutsu Studio app on this Mac, which makes AI videos and images with Higgsfield and keeps them in \
        its Library. Call capabilities first: it says how the app is connected (an API key paying in USD, or an \
        account paying in credits), today's agent budget (dailyLimit, spentToday, reservedToday, remaining, in \
        usd_cents or credits) and the tool groups this version offers; models: true lists the video models, model: \
        an ID gives that model's limits, image_models, styles and voices list what create_image, Restyle and \
        change_voice take. Agents are off until the person turns on Settings › Agents › Allow agents; until then \
        every tool returns agents_off. To make a video: quote it (free), then create_video with a new request_id and \
        max_cost, the most you agree to pay; create_image and enhance take the same two. Use a cheap draft mode \
        when it fits the task. Sending the same request_id and parameters again returns the same job and never pays \
        twice; reuse a request_id only to retry. Follow jobs with jobs, wait_seconds up to 50; a wait that runs out \
        stops nothing. Jutsu Studio checks every paid request right before it is sent: a price above max_cost, \
        above what is left of the daily agent budget or not known holds it (paused, needsPerson) until the person \
        decides in the Queue; the person's own daily cap applies too. Tell the person when something waits for \
        them. library_search finds results (paths on this Mac), library_mark keeps, rejects or stars them, \
        delivery_set and export write files for delivery or editing, never over a file. job_action cancels, \
        retries or runs a job next, or pauses or resumes the queue; it never resumes a job waiting for the person, \
        and nothing here deletes anything. show opens a page or a job for the person to see. A failed call returns \
        error with code, message, retryable and next: follow next.
        """

    // MARK: Encoding

    private static func encode(result: JSONValue, id: JSONValue) -> Data? {
        try? AgentWire.line(["jsonrpc": "2.0", "id": id, "result": result] as JSONValue)
    }

    private static func encode(error code: RPCError.Code, _ message: String, id: JSONValue) -> Data? {
        encode(RPCError(code, message), id: id)
    }

    private static func encode(_ error: RPCError, id: JSONValue) -> Data? {
        var body: [String: JSONValue] = [
            "code": .number(Double(error.code.rawValue)), "message": .string(error.message),
        ]
        if let data = error.data { body["data"] = data }
        return try? AgentWire.line(["jsonrpc": "2.0", "id": id, "error": .object(body)] as JSONValue)
    }
}

/// A JSON-RPC error answer, for a call that is malformed rather than one a tool refused.
struct RPCError: Error {
    enum Code: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case unsupportedProtocolVersion = -32022
    }

    var code: Code
    var message: String
    var data: JSONValue?

    init(_ code: Code, _ message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}
