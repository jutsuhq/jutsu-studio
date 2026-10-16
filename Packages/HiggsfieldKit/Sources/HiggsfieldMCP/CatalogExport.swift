import Foundation
import HiggsfieldCore

extension HiggsfieldAccount {
    /// `models_explore` pages read per media type, at most, so a token chain that never ends can't loop.
    static let maxModelPages = 20
    /// The most items a `models_explore` `list` page holds (its schema's `limit` maximum; the default is 20).
    static let modelPageSize = 100
    /// The `type` values `models_explore` lists models for.
    static let exploredTypes = ["video", "image", "audio"]
    /// The `type`s whose listed models are each described with `get` too.
    static let describedTypes: Set<String> = ["video", "image"]

    /// The server's tool and model catalogs as pretty-printed, key-sorted JSON, to check the docs and the
    /// arguments the app sends against the live server. Calls only free, read-only tools: `tools/list`, then
    /// `models_explore` with `list` for each type in `exploredTypes` and `get` for each video and image model
    /// the lists name (`describedTypes`).
    ///
    /// Holds only what the server answered and the time of the export: never the access token or the session
    /// ID, which live in `MCPClient`'s headers. Every occurrence of a string in `redacting` (the account's
    /// email, say) is replaced, in case an answer echoes it. Without `models_explore`, `models` is `null`;
    /// a `models_explore` call the server refuses is kept with its error rather than ending the export.
    public func exportCatalog(redacting: [String] = []) async throws -> Data {
        let tools = try await mapErrors { try await client.listToolValues() }
        let models: JSONValue =
            if tools.contains(where: { $0["name"]?.stringValue == ToolKey.modelsExplore }) {
                try await exploreModels()
            } else {
                .null
            }
        let export: JSONValue = [
            "exportedAt": .string(ISO8601DateFormatter().string(from: now())),
            "protocolVersion": .string(MCPClient.protocolVersion),
            "tools": .array(tools), "models": models,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export.redacting(redacting.filter { !$0.isEmpty }))
    }

    /// `{"list": {type: [page…]}, "get": {model_id: answer}}`.
    private func exploreModels() async throws -> JSONValue {
        var lists: [String: JSONValue] = [:]
        var described: [String] = []
        for type in Self.exploredTypes {
            var pages: [JSONValue] = []
            var arguments = Self.modelList(type: type)
            var seenTokens: Set<String> = []
            for _ in 0..<Self.maxModelPages {
                let (record, next) = try await explore(arguments)
                pages.append(record)
                guard let next, seenTokens.insert(next).inserted else { break }
                arguments[ToolKey.after] = .string(next)
            }
            lists[type] = .array(pages)
            if Self.describedTypes.contains(type) {
                described += pages.flatMap { UnlimitedAllowance.items(in: $0["structuredContent"] ?? .null) }
                    .compactMap(UnlimitedAllowance.modelID)
            }
        }
        var models: [String: JSONValue] = [:]
        for id in described where models[id] == nil {
            models[id] = try await explore([ToolKey.action: .string(ToolKey.get), ToolKey.modelID: .string(id)])
                .record
        }
        return ["list": .object(lists), "get": .object(models)]
    }

    /// One `models_explore` call: its arguments with the whole answer, and the next page's token if it names one.
    private func explore(_ arguments: [String: JSONValue]) async throws -> (record: JSONValue, next: String?) {
        let page: (result: MCPToolResult, next: String?)
        do {
            page = try await exploreModels(arguments)
        } catch HiggsfieldError.validation(_, let message) {
            return (["arguments": .object(arguments), "error": .string(message)], nil)
        }
        let result = page.result
        let record: JSONValue = [
            "arguments": .object(arguments), "isError": .bool(result.isError), "content": .array(result.content),
            "structuredContent": result.structuredContent ?? .null,
        ]
        return (record, page.next)
    }

    /// The arguments of the first `models_explore` `list` page of `type`, `modelPageSize` models long.
    static func modelList(type: String) -> [String: JSONValue] {
        [
            ToolKey.action: .string(ToolKey.list), ToolKey.type: .string(type),
            ToolKey.limit: .number(Double(modelPageSize)),
        ]
    }

    /// One `models_explore` call by the tool's name, and the token of the next page, which goes back in `after`:
    /// the answer's `next_page_token`, unless `has_more` is `false` (catalog snapshot of 2026-10-15).
    func exploreModels(_ arguments: [String: JSONValue]) async throws -> (result: MCPToolResult, next: String?) {
        let result = try await mapErrors { try await client.callTool(ToolKey.modelsExplore, arguments: arguments) }
        guard !result.isError, let value = result.value, value[ToolKey.hasMore] != false else { return (result, nil) }
        let token = value[ToolKey.nextPageToken]?.stringValue
        return (result, token?.isEmpty == false ? token : nil)
    }
}

extension JSONValue {
    /// A copy with every occurrence of `secrets` in strings and object keys replaced by `<redacted>`.
    func redacting(_ secrets: [String]) -> JSONValue {
        guard !secrets.isEmpty else { return self }
        func scrub(_ text: String) -> String {
            secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
        }
        switch self {
        case .string(let text): return .string(scrub(text))
        case .array(let values): return .array(values.map { $0.redacting(secrets) })
        case .object(let object):
            let pairs = object.map { (scrub($0.key), $0.value.redacting(secrets)) }
            return .object(Dictionary(pairs, uniquingKeysWith: { first, _ in first }))
        case .null, .bool, .number, .integer, .unsignedInteger: return self
        }
    }
}
