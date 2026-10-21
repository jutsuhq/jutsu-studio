import HiggsfieldMCP
import JutsuAgent

/// The output schemas `tools/list` promises, and the shapes the tools share.
extension Tool {
    /// The answer's shape. Nothing is required at the top, so a tool error, `{"error": {…}}`, fits it too.
    var outputSchema: [String: JSONValue] {
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
                    "reservedToday": ["type": "integer"], "remaining": ["type": "integer"],
                    "unlimitedAllowed": ["type": "boolean"],
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
                        "available": ["type": "boolean"], "details": ["type": "object"],
                    ],
                ],
            ]
            properties["imageModels"] = [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"], "title": ["type": "string"],
                        "counts": ["type": "array", "items": ["type": "integer"]],
                        "aspectRatios": ["type": "array", "items": ["type": "string"]],
                        "input": ["type": "string", "enum": ["none", "optional", "required"]],
                        "maxInputs": ["type": "integer"],
                    ],
                ],
            ]
            properties["styles"] = [
                "type": "array",
                "items": ["type": "object", "properties": ["id": ["type": "string"], "name": ["type": "string"]]],
            ]
            properties["voices"] = [
                "type": "array",
                "items": ["type": "object", "properties": ["id": ["type": "string"], "name": ["type": "string"]]],
            ]
        case .quote:
            properties["price"] = Self.amountSchema
            properties["isExact"] = ["type": "boolean"]
            properties["mode"] = ["type": "string"]
            properties["model"] = ["type": "string"]
            properties["resolution"] = ["type": "string"]
            properties["duration"] = ["type": "number"]
            properties["remainingToday"] = ["type": "integer"]
            properties["paysUnlimited"] = ["type": "boolean"]
            properties["blocker"] = ["type": "string"]
        case .createVideo, .createImage, .enhance:
            properties["requestId"] = ["type": "string"]
            properties["known"] = ["type": "boolean"]
            properties["jobs"] = ["type": "array", "items": Self.jobSchema]
        case .jobs:
            properties["jobs"] = ["type": "array", "items": Self.jobSchema]
            properties["timedOut"] = ["type": "boolean"]
            properties["nextCursor"] = ["type": "string"]
        case .librarySearch:
            properties["items"] = ["type": "array", "items": Self.itemSchema]
            properties["nextCursor"] = ["type": "string"]
        case .libraryGet:
            properties["items"] = [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "item": Self.itemSchema, "inputs": ["type": "array", "items": Self.inputSchema],
                        "settings": Self.settingsSchema,
                    ],
                ],
            ]
        case .libraryMark:
            properties["items"] = [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"], "verdict": ["type": "string"], "starred": ["type": "boolean"],
                    ],
                ],
            ]
            properties["changed"] = ["type": "integer"]
        case .deliverySet:
            properties["action"] = ["type": "string"]
            properties["set"] = Self.deliverySetSchema
            properties["sets"] = ["type": "array", "items": Self.deliverySetSchema]
            properties["folders"] = ["type": "array", "items": ["type": "string"]]
            properties["job"] = Self.jobSchema
            properties["timedOut"] = ["type": "boolean"]
        case .export:
            properties["job"] = Self.jobSchema
            properties["timedOut"] = ["type": "boolean"]
        case .jobAction:
            properties["action"] = ["type": "string"]
            properties["job"] = Self.jobSchema
        case .show:
            properties["page"] = [
                "type": "string", "enum": .array(AgentPage.allCases.map { .string($0.rawValue) }),
            ]
            properties["job"] = ["type": "string"]
        }
        return ["type": "object", "properties": .object(properties)]
    }

    static let amountSchema: JSONValue = [
        "type": "object",
        "properties": ["amount": ["type": "integer"], "unit": ["type": "string", "enum": ["usd_cents", "credits"]]],
    ]

    static let jobSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string"], "state": ["type": "string"], "pauseReason": ["type": "string"],
            "hold": ["type": "string"], "needsPerson": ["type": "boolean"], "progress": ["type": "number"],
            "price": amountSchema, "isPriceExact": ["type": "boolean"], "charged": ["type": "boolean"],
            "error": ["type": "string"], "result": ["type": "string"],
            "results": ["type": "array", "items": ["type": "string"]], "kind": ["type": "string"],
            "requestId": ["type": "string"],
            "client": ["type": "string"], "mode": ["type": "string"], "model": ["type": "string"],
            "folder": ["type": "string"], "files": ["type": "array", "items": exportFileSchema],
            "set": ["type": "string"], "next": ["type": "string"],
            "createdAt": ["type": "string"], "finishedAt": ["type": "string"],
        ],
    ]

    static let itemSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string"], "kind": ["type": "string"], "file": ["type": "string"],
            "model": ["type": "string"], "mode": ["type": "string"], "aspectRatio": ["type": "string"],
            "duration": ["type": "number"], "price": amountSchema, "verdict": ["type": "string"],
            "starred": ["type": "boolean"], "createdAt": ["type": "string"], "prompt": ["type": "string"],
            "promptTruncated": ["type": "boolean"], "versionId": ["type": "string"], "version": ["type": "integer"],
            "versionCount": ["type": "integer"], "jobId": ["type": "string"],
        ],
    ]

    static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "role": ["type": "string", "enum": .array(AgentLibraryInput.Role.allCases.map { .string($0.rawValue) })],
            "position": ["type": "integer"], "file": ["type": "string"], "item": ["type": "string"],
            "onHiggsfield": ["type": "boolean"], "start": ["type": "number"], "end": ["type": "number"],
        ],
    ]

    static let settingsSchema: JSONValue = [
        "type": "object",
        "properties": [
            "resolution": ["type": "string"], "draft": ["type": "boolean"], "audio": ["type": "string"],
            "style": ["type": "string"], "length": ["type": "number"], "aspectRatio": ["type": "string"],
            "paidWithUnlimited": ["type": "boolean"], "operation": ["type": "string"], "count": ["type": "integer"],
        ],
    ]

    static let deliverySetSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string"], "name": ["type": "string"], "createdAt": ["type": "string"],
            "itemCount": ["type": "integer"], "frozen": ["type": "boolean"], "exportedAt": ["type": "string"],
            "folder": ["type": "string"], "outputs": ["type": "array", "items": ["type": "string"]],
        ],
    ]

    static let exportFileSchema: JSONValue = [
        "type": "object",
        "properties": [
            "item": ["type": "string"], "status": ["type": "string", "enum": ["done", "failed", "skipped"]],
            "file": ["type": "string"], "sidecar": ["type": "string"], "message": ["type": "string"],
            "output": ["type": "string"],
        ],
    ]

    static let requestIDSchema: JSONValue = [
        "type": "string", "pattern": "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$",
        "description": "Your own new ID for this request; the same one again only to retry it.",
    ]

    static let maxCostSchema: JSONValue = [
        "type": "object", "additionalProperties": false,
        "description": "The most you agree to pay for this request, in the connection's unit.",
        "properties": [
            "amount": ["type": "number", "minimum": 0],
            "unit": ["type": "string", "enum": ["usd", "credits"]],
        ],
        "required": ["amount", "unit"],
    ]

    static let errorSchema: JSONValue = [
        "type": "object",
        "description": "Why the call failed: code to branch on, message for the person, next for what to do.",
        "properties": [
            "code": ["type": "string"], "message": ["type": "string"], "retryable": ["type": "boolean"],
            "next": ["type": "string"],
        ],
        "required": ["code", "message", "retryable"],
    ]
}
