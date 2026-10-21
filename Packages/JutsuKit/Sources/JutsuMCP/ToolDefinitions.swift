import HiggsfieldMCP
import JutsuAgent

/// What `tools/list` shows of each tool: its name, what it does, its input and output schemas and hints.
extension Tool {
    /// - Parameter structured: whether the client reads `structuredContent` (2025-06-18 on); only then is there an
    ///   output schema to promise it.
    func definition(structured: Bool) -> JSONValue {
        var definition: [String: JSONValue] = [
            "name": .string(rawValue), "title": .string(title), "description": .string(about),
            "inputSchema": .object(inputSchema), "annotations": annotations,
        ]
        if structured { definition["outputSchema"] = .object(outputSchema) }
        return .object(definition)
    }

    private var title: String {
        switch self {
        case .capabilities: "Jutsu Studio capabilities"
        case .show: "Show in Jutsu Studio"
        }
    }

    private var about: String {
        switch self {
        case .capabilities:
            """
            What Jutsu Studio can do now: the app version, how it is connected to Higgsfield (none, apiKey or \
            account) with the account's plan and credits when known, today's agent budget in whole units \
            (usd_cents with an API key, credits on an account: dailyLimit, spentToday, remaining) and the tool \
            groups this version offers. models: true adds the video models (id, title, modes, resolutions, whether \
            the connection runs it); model: an ID returns only that one. Free, and never shows a credential.
            """
        case .show:
            """
            Opens a page of Jutsu Studio for the person and brings its window to the front: page (create, queue, \
            library or settings), or job, a job ID, which opens a finished job's result in Library and any other \
            job's row in the Queue. Give exactly one. Changes nothing but what the window shows.
            """
        }
    }

    private var inputSchema: [String: JSONValue] {
        var schema: [String: JSONValue] = ["type": "object", "additionalProperties": false]
        switch self {
        case .capabilities:
            schema["properties"] = [
                "models": ["type": "boolean", "description": "Adds the video models to the answer."],
                "model": [
                    "type": "string", "pattern": "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$",
                    "description": "Only this model, by its ID.",
                ],
            ]
        // Exactly one of the two, said in words and checked on the call: some model APIs refuse oneOf at the top of
        // an input schema.
        case .show:
            schema["properties"] = [
                "page": [
                    "type": "string", "enum": .array(AgentPage.allCases.map { .string($0.rawValue) }),
                    "description": "A page of the sidebar.",
                ],
                "job": ["type": "string", "format": "uuid", "description": "A job ID."],
            ]
        }
        return schema
    }

    /// The answer's shape. Nothing is required at the top, so a tool error, `{"error": {…}}`, fits it too.
    private var outputSchema: [String: JSONValue] {
        var properties: [String: JSONValue] = ["error": Self.errorSchema]
        switch self {
        case .capabilities:
            properties["protocolVersion"] = ["type": "integer"]
            properties["appVersion"] = ["type": "string"]
            properties["agentsAllowed"] = ["type": "boolean"]
            properties["connection"] = [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": ["none", "apiKey", "account"]],
                    "plan": ["type": "string"], "credits": ["type": "integer"],
                ],
            ]
            properties["budget"] = [
                "type": "object",
                "properties": [
                    "unit": ["type": "string", "enum": ["usd_cents", "credits"]],
                    "dailyLimit": ["type": "integer"], "spentToday": ["type": "integer"],
                    "remaining": ["type": "integer"],
                ],
            ]
            properties["toolGroups"] = [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"], "tools": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
            ]
            properties["models"] = [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"], "title": ["type": "string"],
                        "modes": ["type": "array", "items": ["type": "string"]],
                        "resolutions": ["type": "array", "items": ["type": "string"]],
                        "available": ["type": "boolean"],
                    ],
                ],
            ]
        case .show:
            properties["page"] = [
                "type": "string", "enum": .array(AgentPage.allCases.map { .string($0.rawValue) }),
            ]
            properties["job"] = ["type": "string"]
        }
        return ["type": "object", "properties": .object(properties)]
    }

    static let errorSchema: JSONValue = [
        "type": "object",
        "description": "Why the call failed: code to branch on, message for the person, next for what to do.",
        "properties": [
            "code": ["type": "string"], "message": ["type": "string"], "retryable": ["type": "boolean"],
            "next": ["type": "string"],
        ],
        "required": ["code", "message", "retryable"],
    ]

    private var annotations: JSONValue {
        switch self {
        case .capabilities:
            ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        // Changes what the window shows, nothing else.
        case .show:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        }
    }
}
