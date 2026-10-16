import Foundation

/// A tool from `tools/list`.
public struct MCPTool: Codable, Sendable, Hashable {
    public var name: String
    public var description: String?
    /// JSON Schema of the arguments.
    public var inputSchema: JSONValue

    public init(name: String, description: String? = nil, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    public var argumentNames: Set<String> {
        Set((inputSchema["properties"]?.objectValue ?? [:]).keys)
    }
}

/// The result of `tools/call`.
public struct MCPToolResult: Decodable, Sendable, Hashable {
    public var content: [JSONValue]
    public var structuredContent: JSONValue?
    public var isError: Bool

    enum CodingKeys: String, CodingKey {
        case content, structuredContent, isError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([JSONValue].self, forKey: .content) ?? []
        structuredContent = try container.decodeIfPresent(JSONValue.self, forKey: .structuredContent)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }

    /// `structuredContent`, else the first text block parsed as JSON, else that text as a string.
    public var value: JSONValue? {
        if let structuredContent { return structuredContent }
        guard let text = content.lazy.compactMap({ $0["text"]?.stringValue }).first else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
    }

    /// The text blocks, joined; servers put error messages here.
    public var text: String {
        content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }
}
