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
        case .quote: "Quote a video"
        case .createVideo: "Create a video"
        case .jobs: "Jobs"
        case .jobAction: "Act on a job or the queue"
        case .show: "Show in Jutsu Studio"
        }
    }

    private var about: String {
        switch self {
        case .capabilities:
            """
            What Jutsu Studio can do now: the app version, how it is connected to Higgsfield (none, apiKey or \
            account) with the account's plan and credits when known, today's agent budget in whole units \
            (usd_cents with an API key, credits on an account: dailyLimit, spentToday, reservedToday for submits \
            not answered yet, remaining) and the tool groups this version offers. models: true adds the video models \
            (id, title, modes, resolutions, whether the connection runs it); model: an ID returns only that one, with \
            its limits per mode (seconds, images, whether it needs a style or a source). Free, and never shows a \
            credential.
            """
        case .quote:
            """
            What a video would cost now, with the same parameters as create_video, without uploading or queueing \
            anything: the price in whole usd_cents or credits (null when not known before upload), whether it is \
            exact, what is left of today's agent budget, and blocker, why create_video would refuse it now. A source \
            needs end (its start and end in seconds) instead of a file; images may be paths or image_count. Free.
            """
        case .createVideo:
            """
            Queues one video in Jutsu Studio, made exactly as the Create screen would make it and checked by the \
            same rules and model limits. request_id is your own new ID for this request; sending the same request_id \
            with the same parameters again returns the same job and never queues or pays twice, and another request \
            under a used request_id is refused with request_conflict. max_cost {amount, unit: usd or credits} is the \
            most you agree to pay: right before the job is paid for, a price above it, above what is left of the \
            daily agent budget or not known pauses the job (state paused, pauseReason agent_limit) until the person \
            confirms it in the app. Files (source.path, images) are paths on this Mac, copied into the app. Returns \
            the job; follow it with jobs.
            """
        case .jobs:
            """
            The state of jobs by ID (ids, up to 20), or of the latest jobs agents queued (limit, up to 50): state, \
            pauseReason, hold, needsPerson, progress, price, error, and result, the finished video's path. \
            wait_seconds (0–50) waits until every job named has settled (done, failed, rejected, canceled or \
            paused); a wait that runs out returns the state as it is, with timedOut, and stops nothing. Read-only.
            """
        case .jobAction:
            """
            cancel, retry or run_next a job an agent queued (job: its ID), or pause_queue or resume_queue for every \
            job not yet sent. retry is refused when the job may already have been charged; resume_queue never \
            resumes a job paused for its price or the agent limits, which only the person can. Nothing is deleted.
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
        case .quote:
            schema["properties"] = .object(Self.videoProperties(files: false))
            schema["required"] = ["mode"]
        case .createVideo:
            var properties = Self.videoProperties(files: true)
            properties["request_id"] = [
                "type": "string", "pattern": "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$",
                "description": "Your own new ID for this request; the same one again only to retry it.",
            ]
            properties["max_cost"] = [
                "type": "object", "additionalProperties": false,
                "description": "The most you agree to pay for this job, in the connection's unit.",
                "properties": [
                    "amount": ["type": "number", "minimum": 0],
                    "unit": ["type": "string", "enum": ["usd", "credits"]],
                ],
                "required": ["amount", "unit"],
            ]
            schema["properties"] = .object(properties)
            schema["required"] = ["request_id", "mode", "max_cost"]
        case .jobs:
            schema["properties"] = [
                "ids": [
                    "type": "array", "maxItems": .number(Double(JobsCommand.maxIDs)),
                    "items": ["type": "string", "format": "uuid"], "description": "Job IDs.",
                ],
                "limit": [
                    "type": "integer", "minimum": 1, "maximum": .number(Double(JobsCommand.maxLimit)),
                    "description": "Without ids: how many of the latest agent jobs, newest first.",
                ],
                "wait_seconds": [
                    "type": "integer", "minimum": 0, "maximum": .number(Double(JobsCommand.maxWaitSeconds)),
                    "description": "Wait up to this long for the jobs to settle.",
                ],
            ]
        case .jobAction:
            schema["properties"] = [
                "action": ["type": "string", "enum": .array(AgentJobAction.allCases.map { .string($0.rawValue) })],
                "job": [
                    "type": "string", "format": "uuid", "description": "The job, for cancel, retry and run_next.",
                ],
            ]
            schema["required"] = ["action"]
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

    /// The video fields of `quote` and `create_video`; `files` for paths to send, else counts and lengths only.
    private static func videoProperties(files: Bool) -> [String: JSONValue] {
        var source: [String: JSONValue] = [
            "start": ["type": "number", "minimum": 0, "description": "Seconds from the start of the file."],
            "end": ["type": "number", "minimum": 0, "description": "Where the job's range ends, in seconds."],
        ]
        if files { source["path"] = ["type": "string", "description": "The clip on this Mac."] }
        var properties: [String: JSONValue] = [
            "mode": ["type": "string", "enum": .array(AgentVideoRequest.modes.map { .string($0) })],
            "model": [
                "type": "string", "description": "A model ID from capabilities; the mode's default if left out.",
            ],
            "prompt": ["type": "string", "maxLength": 10_000],
            "source": [
                "type": "object", "additionalProperties": false, "properties": .object(source),
                "description": files
                    ? "The source clip; left out, a model that can makes the clip from the prompt and images."
                    : "The source clip's range; end is needed.",
            ],
            "images": [
                "type": "array", "maxItems": .number(Double(AgentVideoRequest.maxImages)),
                "items": ["type": "string"], "description": "Reference images on this Mac, in order.",
            ],
            "style": ["type": "string", "format": "uuid", "description": "Restyle's style ID."],
            "resolution": ["type": "string", "description": "One from capabilities, such as 720p."],
            "draft": ["type": "boolean", "description": "A cheaper lower-resolution preview, on models with drafts."],
            "length": [
                "type": "number", "exclusiveMinimum": 0,
                "description": "Seconds a clip without a source runs, or extend adds.",
            ],
            "aspect_ratio": ["type": "string", "description": "A clip without a source: 16:9, 9:16, 1:1…"],
            "audio": ["type": "string", "enum": .array(AgentVideoRequest.audioOptions.map { .string($0) })],
            "variants": ["type": "integer", "minimum": 1, "description": "Videos one submit makes, where offered."],
        ]
        if !files {
            properties["image_count"] = [
                "type": "integer", "minimum": 0, "description": "How many reference images there will be.",
            ]
        }
        return properties
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
                    "reservedToday": ["type": "integer"], "remaining": ["type": "integer"],
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
        case .quote:
            properties["price"] = Self.amountSchema
            properties["isExact"] = ["type": "boolean"]
            properties["mode"] = ["type": "string"]
            properties["model"] = ["type": "string"]
            properties["resolution"] = ["type": "string"]
            properties["duration"] = ["type": "number"]
            properties["remainingToday"] = ["type": "integer"]
            properties["blocker"] = ["type": "string"]
        case .createVideo:
            properties["requestId"] = ["type": "string"]
            properties["known"] = ["type": "boolean"]
            properties["jobs"] = ["type": "array", "items": Self.jobSchema]
        case .jobs:
            properties["jobs"] = ["type": "array", "items": Self.jobSchema]
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
            "error": ["type": "string"], "result": ["type": "string"], "requestId": ["type": "string"],
            "client": ["type": "string"], "mode": ["type": "string"], "model": ["type": "string"],
            "createdAt": ["type": "string"], "finishedAt": ["type": "string"],
        ],
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

    private var annotations: JSONValue {
        switch self {
        case .capabilities, .quote, .jobs:
            ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        // Spends, but the same request_id never queues twice; it reaches Higgsfield.
        case .createVideo:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]
        // Cancel stops a job, retry may queue another attempt.
        case .jobAction:
            ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true]
        // Changes what the window shows, nothing else.
        case .show:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        }
    }
}
