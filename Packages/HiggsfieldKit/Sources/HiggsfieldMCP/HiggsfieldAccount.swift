import Foundation
import HiggsfieldCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The tools of Higgsfield's MCP server as typed calls. Which tools exist is read from `tools/list` and kept;
/// a tool missing from that list is looked for once more in a fresh one, so a server that gained it since
/// recovers without reconnecting. Every failure surfaces as `HiggsfieldError`, or `CancellationError`.
public actor HiggsfieldAccount {
    /// How old the catalog must be before an optional tool's absence (`balance`) is checked again. A missing
    /// tool that a call needs is always checked again, as the call fails otherwise; `balance` is asked for
    /// routinely and its absence is a normal answer, so without this floor it would re-list every time.
    static let optionalToolRecheck: TimeInterval = 60

    let client: MCPClient
    private let session: URLSession
    let now: @Sendable () -> Date
    private var catalog: ToolCatalog?
    private var catalogLoadedAt = Date.distantPast

    /// - Parameter session: used only to PUT files to the upload URLs the server hands out.
    public init(client: MCPClient, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.session = session
        self.now = now
    }

    /// Re-reads `tools/list`. `true` when every tool a generation needs is there with the arguments it takes.
    @discardableResult
    public func refreshTools() async throws -> Bool {
        let catalog = ToolCatalog(try await mapErrors { try await client.listTools() })
        self.catalog = catalog
        catalogLoadedAt = now()
        return catalog.canGenerate
    }

    /// Whether the last `tools/list` had every tool a Genjutsu Style needs; `false` before one was read.
    public var canRunStyles: Bool { catalog?.canRunStyles ?? false }

    /// Throws `HiggsfieldError.toolUnavailable` when the account has no usable `generate_video`.
    public func checkGenerate() async throws {
        _ = try await tool(.generate)
    }

    /// The exact price in credits; submits nothing. The server prices only uploaded files.
    public func cost(of request: VideoRequest) async throws -> Double {
        guard let credits = Self.credits(in: try await send(request, getCost: true)[ToolKey.cost]) else {
            throw unexpected(.generate)
        }
        return credits
    }

    /// Not idempotent: the tool takes no idempotency key, so sending a request again may pay twice. A reply that
    /// names no job and gives no reason throws `.server(status: 200)`: the call went through and may have started
    /// a generation, so it must not be read as a refusal that is safe to send again. Every `results[].id` is a job
    /// to poll: the first is the generation's `id`, the others, one per further variant (`count`), its
    /// `variantIDs`. A result without an ID is skipped rather than failing the answer, so the jobs it does name
    /// are kept.
    public func generate(_ request: VideoRequest) async throws -> Generation {
        let value = try await send(request, getCost: false)
        var ids: [String] = []
        for id in (value[ToolKey.results]?.arrayValue ?? []).compactMap({ $0[ToolKey.id]?.stringValue })
        where !ids.contains(id) {
            ids.append(id)
        }
        guard let id = ids.first else { throw Self.noJobStarted(value) }
        return Generation(
            id: id, requestID: value[ToolKey.requestID]?.stringValue, credits: Self.credits(in: value[ToolKey.cost]),
            variantIDs: Array(ids.dropFirst()))
    }

    /// Asks for an upload URL, PUTs the file there and confirms it. The server tells video from image by the
    /// file name's extension. An upload URL that isn't https is never opened.
    public func upload(fileAt fileURL: URL, contentType: String) async throws -> UploadedMedia {
        let value = try await call(
            .upload,
            [ToolKey.filename: .string(fileURL.lastPathComponent), ToolKey.contentType: .string(contentType)])
        guard let slot = value[ToolKey.uploads]?.arrayValue?.first,
            let mediaID = slot[ToolKey.mediaID]?.stringValue,
            let uploadURL = slot[ToolKey.uploadURL]?.stringValue.flatMap(URL.init(string:)), uploadURL.isHTTPS,
            let url = slot[ToolKey.url]?.stringValue.flatMap(URL.init(string:))
        else { throw failure(value, role: .upload) }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.send(request, fromFile: fileURL)
        guard response.isSuccess else { throw HiggsfieldError.server(status: response.statusCode) }
        let type = contentType.hasPrefix("video/") ? "video" : "image"
        let confirmed = try await call(
            .confirmUpload, [ToolKey.mediaID: .string(mediaID), ToolKey.type: .string(type)])
        if let error = confirmed[ToolKey.error]?.stringValue {
            throw HiggsfieldError.validation(field: nil, message: error)
        }
        return UploadedMedia(id: mediaID, url: url)
    }

    /// `media_import_url`: the server fetches an https file of at most `importLimit` bytes itself and answers with a
    /// confirmed `media_id`, which `medias` take like an upload's. `type` is "video" or "image"; the server checks
    /// it against the file's content type. A refusal (`isError`, `error`, or no `media_id`) throws `.validation`.
    public func importMedia(from url: URL, type: String) async throws -> String {
        let value = try await call(
            .importMedia, [ToolKey.url: .string(url.absoluteString), ToolKey.type: .string(type)])
        guard let mediaID = value[ToolKey.mediaID]?.stringValue, !mediaID.isEmpty else {
            throw failure(value, role: .importMedia)
        }
        return mediaID
    }

    /// `media_import_url`'s limit: "Max URL payload: 50 MB".
    public static let importLimit: Int64 = 50_000_000

    public func status(of generationID: String) async throws -> GenerationStatus {
        let value = try await call(.status, [ToolKey.jobID: .string(generationID)])
        guard let generation = value[ToolKey.generation] else {
            // A stated error ("Job not found") ends the job; an answer with neither is polled again, since the job
            // may be paid and running.
            throw value[ToolKey.error] == nil ? HiggsfieldError.server(status: 200) : unexpected(.status)
        }
        // Ends the job, as REST's `.failed` does for a completed job without a URL (or one that isn't https):
        // polling again won't bring one. Reported as a broken answer: the tool's `outputSchema` promises `rawUrl`.
        guard let status = Self.status(of: generation, error: value[ToolKey.error]) else { throw unexpected(.status) }
        return status
    }
    /// `nil` when the account exposes no balance tool.
    public func balance() async throws -> AccountBalance? {
        guard try await lookUp(.balance, recheckingAfter: Self.optionalToolRecheck) != nil else { return nil }
        let value = try await call(.balance, [:])
        guard let credits = value[ToolKey.credits]?.numberValue else { throw unexpected(.balance) }
        return AccountBalance(credits: credits, plan: value[ToolKey.plan]?.stringValue)
    }

    /// A page of the account's history in its selected workspace, newest first.
    /// - Parameters:
    ///   - type: `nil` for every media type.
    ///   - cursor: `nextCursor` of the page before, as it came.
    ///   - size: 1–100.
    public func generations(
        type: GenerationType? = .video, onlyCompleted: Bool = true, cursor: JSONValue? = nil, size: Int = 24
    ) async throws -> GenerationPage {
        var arguments: [String: JSONValue] = [
            ToolKey.size: .number(Double(min(max(size, 1), 100))), ToolKey.onlyCompleted: .bool(onlyCompleted),
        ]
        if let type { arguments[ToolKey.type] = .string(type.rawValue) }
        if let cursor, cursor != .null { arguments[ToolKey.cursor] = cursor }
        guard let page = GenerationPage(try await call(.generations, arguments)) else {
            throw unexpected(.generations)
        }
        return page
    }

    /// Likes or unlikes a generation of the account; setting the state it already has is harmless.
    public func setLiked(_ generationID: String, liked: Bool) async throws {
        _ = try await call(.like, [ToolKey.jobIDSingle: .string(generationID), ToolKey.liked: .bool(liked)])
    }

    /// A page of the account's credit movements, newest first.
    /// - Parameters:
    ///   - cursor: `nextCursor` of the page before, as it came.
    ///   - size: 1–100.
    public func transactions(cursor: JSONValue? = nil, size: Int = 30) async throws -> CreditTransactionPage {
        var arguments: [String: JSONValue] = [ToolKey.size: .number(Double(min(max(size, 1), 100)))]
        if let cursor, cursor != .null { arguments[ToolKey.cursor] = cursor }
        guard let page = CreditTransactionPage(try await call(.transactions, arguments)) else {
            throw unexpected(.transactions)
        }
        return page
    }

    /// A page of the files the account uploaded, newest first.
    /// - Parameters:
    ///   - cursor: `nextCursor` of the page before, as it came.
    ///   - size: 1–50.
    public func uploads(_ kind: AssetKind, cursor: JSONValue? = nil, size: Int = 30) async throws -> AccountAssetPage {
        try await assets(source: ToolKey.uploads, kind: kind, cursor: cursor, size: size)
    }

    /// A page of `assets_picker_list` of `source` (`uploads`, `generations`, `liked`, `influencer`,
    /// `influencer-liked`), newest first.
    func assets(source: String, kind: AssetKind, cursor: JSONValue?, size: Int) async throws -> AccountAssetPage {
        var arguments: [String: JSONValue] = [
            ToolKey.source: .string(source), ToolKey.kind: .string(kind.rawValue),
            ToolKey.size: .number(Double(min(max(size, 1), 50))),
        ]
        if let cursor, cursor != .null { arguments[ToolKey.cursor] = cursor }
        guard let page = AccountAssetPage(try await call(.assets, arguments)) else { throw unexpected(.assets) }
        return page
    }

    /// A page of a Genjutsu gallery, in the server's order.
    /// - Parameters:
    ///   - cursor: `nextCursor` of the page before, as it came.
    ///   - limit: 1–50.
    public func genjutsuPresets(
        _ category: GenjutsuCategory, cursor: JSONValue? = nil, limit: Int = 24
    ) async throws -> GenjutsuPresetPage {
        var arguments: [String: JSONValue] = [
            ToolKey.source: .string(ToolKey.genjutsu), ToolKey.category: .string(category.rawValue),
            ToolKey.limit: .number(Double(min(max(limit, 1), 50))),
        ]
        if let cursor, cursor != .null { arguments[ToolKey.cursor] = cursor }
        guard let page = GenjutsuPresetPage(try await call(.presets, arguments)) else { throw unexpected(.presets) }
        return page
    }

    /// The price in credits of `run`; `nil` when the server gives none, as for inputs it doesn't accept.
    /// Opens the style's detail with the inputs filled in; submits nothing.
    public func cost(of run: StyleRun) async throws -> Double? {
        let result = try await callResult(
            .presets,
            [
                ToolKey.source: .string(ToolKey.genjutsu), ToolKey.presetID: .string(run.styleID),
                ToolKey.category: .string(ToolKey.all), ToolKey.initialInputs: run.inputs,
            ])
        return PresetQuote.credits(in: result)
    }

    /// Not idempotent, like `generate(_:)`: a reply that names no job and gives no reason throws
    /// `.server(status: 200)`, as it may have started a run.
    public func run(_ style: StyleRun) async throws -> Generation {
        let value = try await call(
            .executePreset,
            [
                ToolKey.source: .string(ToolKey.genjutsu), ToolKey.presetID: .string(style.styleID),
                ToolKey.inputs: style.inputs,
            ])
        guard let id = PresetQuote.jobID(in: value) else { throw Self.noJobStarted(value) }
        return Generation(id: id, requestID: value[ToolKey.requestID]?.stringValue)
    }

    /// `generate_video`, quoted or submitted. For some prompts the server neither quotes nor submits but suggests a
    /// look-alike preset (`notice.type: preset_recommendation`) and asks to retry with `declined_preset_id` to
    /// use the prompt as written; that is what the user typed, so the suggestion is declined once. A reply that
    /// is still only a notice submitted nothing and throws its message.
    private func send(_ request: VideoRequest, getCost: Bool) async throws -> JSONValue {
        var value = try await call(.generate, request.arguments(getCost: getCost))
        if value[ToolKey.results] == nil, value[ToolKey.cost] == nil,
            value[ToolKey.notice]?["type"] == "preset_recommendation",
            let declined = value[ToolKey.notice]?[ToolKey.data]?[ToolKey.retryLiteral]?[ToolKey.declinedPresetID]?
                .stringValue
        {
            value = try await call(.generate, request.arguments(getCost: getCost, declinedPresetID: declined))
        }
        if let notice = value[ToolKey.notice], value[ToolKey.results] == nil, value[ToolKey.cost] == nil {
            throw HiggsfieldError.validation(
                field: nil, message: notice[ToolKey.message]?.stringValue ?? "Higgsfield didn't take the request")
        }
        return value
    }

    func call(_ role: ToolRole, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await callResult(role, arguments).value ?? .null
    }

    private func callResult(_ role: ToolRole, _ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let name = try await readyToSend(role)
        let result: MCPToolResult
        do {
            result = try await mapErrors { try await client.callTool(name, arguments: arguments) }
        } catch HiggsfieldError.validation where role.readsJobStatus {
            // A refused poll says nothing about the job, which may be paid and still running.
            throw HiggsfieldError.server(status: 200)
        }
        if result.isError {
            if role.readsJobStatus { throw HiggsfieldError.server(status: 200) }
            // An execution error does not prove that a paid tool had no side effects, unless it is one of
            // Higgsfield's refusals before execution (`refusalPrefixes`): that one keeps its reason and lets a job ID
            // be resent as an upload.
            if role.mayStartGeneration, arguments[ToolKey.params]?[ToolKey.getCost] != true,
                !Self.isRefusal(result.text)
            {
                throw HiggsfieldError.server(status: 200)
            }
            throw HiggsfieldError.validation(field: nil, message: result.text)
        }
        return result
    }

    /// The tool's name, with the session and the token in place first for a paid tool: a failure here happens before
    /// anything is sent, so it throws `.notSent` rather than an error that could mean the generation started.
    private func readyToSend(_ role: ToolRole) async throws -> String {
        guard role.mayStartGeneration else { return try await tool(role).name }
        do {
            let name = try await tool(role).name
            try await mapErrors { try await client.prepare() }
            return name
        } catch HiggsfieldError.network, HiggsfieldError.server(status: _) {
            throw HiggsfieldError.notSent
        }
    }

    private func tool(_ role: ToolRole) async throws -> MCPTool {
        guard let tool = try await lookUp(role, recheckingAfter: 0) else {
            throw HiggsfieldError.toolUnavailable(role.rawValue)
        }
        return tool
    }

    /// Reads `tools/list` at most once: when nothing is cached yet, or when `role` is missing from a catalog at
    /// least `minimumAge` seconds old.
    func lookUp(_ role: ToolRole, recheckingAfter minimumAge: TimeInterval) async throws -> MCPTool? {
        if let catalog {
            if let tool = catalog[role] { return tool }
            guard now().timeIntervalSince(catalogLoadedAt) >= minimumAge else { return nil }
        }
        try await refreshTools()
        return catalog?[role]
    }

    /// The server's own reason when it gave one, as for a declined generation or upload.
    func failure(_ value: JSONValue, role: ToolRole) -> HiggsfieldError {
        guard let message = value[ToolKey.error]?.stringValue else { return unexpected(role) }
        return .validation(field: nil, message: message)
    }

    func unexpected(_ role: ToolRole) -> HiggsfieldError {
        .validation(field: nil, message: "Unexpected result from the \(role.rawValue) tool")
    }

    func mapErrors<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch OAuthError.reauthenticationRequired {
            throw HiggsfieldError.unauthorized
        } catch let error as JSONRPCError {
            // Invalid requests, missing methods and invalid arguments are refused before execution.
            guard [-32600, -32601, -32602].contains(error.code) else {
                throw HiggsfieldError.server(status: 200)
            }
            throw HiggsfieldError.validation(field: nil, message: error.message)
        } catch is DecodingError {
            // MCPClient decodes only 2xx replies.
            throw HiggsfieldError.server(status: 200)
        } catch is EncodingError {
            // A request that can't be written, such as a NaN duration, is never sent.
            throw HiggsfieldError.validation(field: nil, message: "The request has a value that can't be sent")
        }
    }
}

/// Readers of the tools' answers.
extension HiggsfieldAccount {
    /// How Higgsfield words an `isError` answer that started nothing, as seen live on 2026-10-15: "Invalid request:"
    /// (an unknown model), and the refused unlimited opt-in ("Error starting generation: Unlimited generations aren't
    /// supported for text2image_soul_v2.", with balance and credit history unchanged).
    static let refusalPrefixes = [
        "Invalid request:", "Error starting generation: Unlimited generations aren't supported",
    ]

    /// What a paid tool's answer that names no job means. With a stated reason (`error`) it is a refusal that started
    /// nothing, thrown as `.validation` with that reason. Without one the call went through and may have started a
    /// paid job, so it throws `.server(status: 200)`, never an error that reads as safe to send again.
    static func noJobStarted(_ value: JSONValue) -> HiggsfieldError {
        guard let message = value[ToolKey.error]?.stringValue else { return .server(status: 200) }
        return .validation(field: nil, message: message)
    }

    /// Whether `text` is one of Higgsfield's refusals before execution (`refusalPrefixes`).
    static func isRefusal(_ text: String) -> Bool {
        refusalPrefixes.contains { text.hasPrefix($0) }
    }

    /// The exact credits of a `cost` block, else its rounded ones.
    static func credits(in cost: JSONValue?) -> Double? {
        (cost?[ToolKey.creditsExact] ?? cost?[ToolKey.credits])?.numberValue
    }

    /// A `generation` object's status; `nil` for a completed one without an https `rawUrl`. A status added later,
    /// or none at all, is most likely another intermediate stage: it reads as in progress, as REST does.
    static func status(of generation: JSONValue, error: JSONValue? = nil) -> GenerationStatus? {
        let message = (generation[ToolKey.error] ?? error)?.stringValue
        switch generation[ToolKey.status]?.stringValue ?? "" {
        case "queued", "pending": return .queued
        case "in_progress", "processing": return .inProgress
        case "failed": return .failed(message: message)
        case "nsfw": return .rejected(.explicitContent)
        case "ip_detected": return .rejected(.protectedContent)
        case "canceled", "cancelled": return .canceled
        case "completed":
            let url = generation[ToolKey.results]?[ToolKey.rawURL]?.stringValue.flatMap(URL.init(serverMedia:))
            return url.map { .completed(videoURL: $0) }
        default:
            return .inProgress
        }
    }
}
