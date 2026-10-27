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
        case .createImage: "Create images"
        case .elements: "Characters and elements"
        case .jobs: "Jobs"
        case .jobAction: "Act on a job or the queue"
        case .librarySearch: "Search the Library"
        case .libraryGet: "Library items in full"
        case .libraryDownload: "Download from Higgsfield"
        case .libraryMark: "Keep, reject or star"
        case .enhance: "Enhance a result"
        case .deliverySet: "Delivery sets"
        case .export: "Export for editing"
        case .frames: "Still frames and contact sheet"
        case .show: "Show in Jutsu Studio"
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
                "image_models": ["type": "boolean", "description": "Adds the image models create_image takes."],
                "styles": ["type": "boolean", "description": "Adds Restyle's style IDs."],
                "voices": ["type": "boolean", "description": "Adds the voices change_voice takes."],
            ]
        case .quote:
            schema["properties"] = .object(Self.videoProperties(files: false))
            schema["required"] = ["mode"]
        case .createVideo:
            var properties = Self.videoProperties(files: true)
            properties["request_id"] = Self.requestIDSchema
            properties["max_cost"] = Self.maxCostSchema
            properties["wait_seconds"] = [
                "type": "integer", "minimum": 0, "maximum": .number(Double(JobsCommand.maxWaitSeconds)),
                "description": "Wait up to this long for the job's price to be known, or for it to be held.",
            ]
            schema["properties"] = .object(properties)
            schema["required"] = ["request_id", "mode", "max_cost"]
        case .createImage:
            schema["properties"] = [
                "request_id": Self.requestIDSchema, "max_cost": Self.maxCostSchema,
                "model": ["type": "string", "description": "An image model ID from capabilities."],
                "prompt": Self.promptSchema,
                "aspect_ratio": ["type": "string", "description": "One the model takes: 1:1, 16:9, 9:16…"],
                "count": [
                    "type": "integer", "minimum": 1, "maximum": .number(Double(AgentImageRequest.maxCount)),
                    "description": "Images to make, one the model offers; 1 when left out.",
                ],
                // No maxItems: the limit is the model's, which capabilities' image_models give.
                "inputs": [
                    "type": "array", "items": ["type": "string"],
                    "description": "Images on this Mac to edit, in order, up to the model's maxInputs.",
                ],
                "input": ["type": "string", "description": "One image to edit: the same as inputs with one item."],
                "elements": [
                    "type": "array", "maxItems": .number(Double(AgentElementNames.maxNames)),
                    "items": ["type": "string", "maxLength": .number(Double(AgentElementNames.maxNameLength))],
                    "description": "The account's elements by name, from the elements tool; their images go first.",
                ],
                "title": Self.titleSchema,
            ]
            schema["required"] = ["request_id", "prompt", "max_cost"]
        case .librarySearch:
            schema["properties"] = [
                "query": ["type": "string", "maxLength": .number(Double(LibrarySearchCommand.maxQueryLength))],
                "kind": ["type": "string", "enum": .array(AgentLibraryKind.allCases.map { .string($0.rawValue) })],
                "starred": ["type": "boolean"],
                "verdict": ["type": "string", "enum": .array(AgentVerdict.allCases.map { .string($0.rawValue) })],
                "include_rejected": ["type": "boolean"],
                "model": [
                    "type": "string", "maxLength": .number(Double(LibrarySearchCommand.maxModelLength)),
                    "description": "A video model ID or an image model's name.",
                ],
                "mode": ["type": "string", "enum": .array(AgentVideoRequest.modes.map { .string($0) })],
                "from": ["type": "string", "format": "date-time"],
                "to": ["type": "string", "format": "date-time"],
                "limit": ["type": "integer", "minimum": 1, "maximum": .number(Double(LibrarySearchCommand.maxLimit))],
                "cursor": ["type": "string", "description": "nextCursor of the page before."],
                "include_higgsfield": [
                    "type": "boolean", "description": "Also the account's Higgsfield history, not on this Mac yet.",
                ],
                "refresh_higgsfield": [
                    "type": "boolean", "description": "Load the history from Higgsfield again first; free.",
                ],
            ]
        case .libraryGet:
            schema["properties"] = [
                "ids": [
                    "type": "array", "minItems": 1, "maxItems": .number(Double(LibraryGetCommand.maxIDs)),
                    "items": ["type": "string", "format": "uuid"], "description": "Library item IDs.",
                ]
            ]
            schema["required"] = ["ids"]
        case .libraryDownload:
            schema["properties"] = [
                "ids": [
                    "type": "array", "minItems": 1, "maxItems": .number(Double(LibraryDownloadCommand.maxIDs)),
                    "items": ["type": "string", "format": "uuid"], "description": "Library item IDs onHiggsfield.",
                ]
            ]
            schema["required"] = ["ids"]
        case .libraryMark:
            schema["properties"] = [
                "ids": [
                    "type": "array", "minItems": 1, "maxItems": .number(Double(LibraryMarkCommand.maxIDs)),
                    "items": ["type": "string", "format": "uuid"], "description": "Library item IDs.",
                ],
                "verdict": ["type": "string", "enum": .array(AgentCulling.allCases.map { .string($0.rawValue) })],
                "star": ["type": "boolean"],
            ]
            schema["required"] = ["ids"]
        case .enhance:
            var maxCost = Self.maxCostSchema.objectValue ?? [:]
            maxCost["description"] =
                "On Higgsfield, the most you agree to pay; a run on this Mac is free and needs none."
            schema["properties"] = [
                "request_id": Self.requestIDSchema, "max_cost": .object(maxCost),
                "item": [
                    "type": "string", "format": "uuid",
                    "description": "A video's Library ID, or an image's for upscale with engine mac.",
                ],
                "operation": [
                    "type": "string", "enum": .array(AgentEnhancement.allCases.map { .string($0.rawValue) }),
                ],
                "target": ["type": "string", "enum": ["1080p", "2k", "4k"]],
                "frame_rate": ["type": "integer", "enum": [24, 30, 60]],
                "engine": [
                    "type": "string", "enum": ["standard", .string(EnhanceCommand.macEngine)],
                    "description": "upscale: standard on Higgsfield (paid), mac on this Mac (free, 4×).",
                ],
                "mode": [
                    "type": "string", "enum": .array(AgentSmoothMotion.allCases.map { .string($0.rawValue) }),
                    "description": "smooth_motion: 60fps keeps length and sound; slow_2x and slow_4x drop the sound.",
                ],
                "aspect_ratio": ["type": "string", "enum": ["9:16", "1:1", "16:9"]],
                "language": ["type": "string", "description": "An ISO 639-3 code, such as fra."],
                "voice": [
                    "type": "string", "minLength": 1, "maxLength": .number(Double(EnhanceCommand.maxVoiceLength)),
                    "description": "A voice ID from capabilities.",
                ],
            ]
            schema["required"] = ["request_id", "item", "operation"]
        case .deliverySet:
            schema["properties"] = [
                "action": [
                    "type": "string", "enum": .array(AgentDeliveryAction.allCases.map { .string($0.rawValue) }),
                ],
                "name": [
                    "type": "string", "maxLength": .number(Double(DeliverySetCommand.maxNameLength)),
                    "description": "create: the set's name.",
                ],
                "items": [
                    "type": "array", "maxItems": .number(Double(DeliverySetCommand.maxItems)),
                    "items": ["type": "string", "format": "uuid"], "description": "create: Library item IDs.",
                ],
                "set": ["type": "string", "format": "uuid", "description": "export: the set's ID."],
                "folder": ["type": "string", "description": "export: one of list's folders."],
                "wait_seconds": Self.exportWaitSchema,
            ]
            schema["required"] = ["action"]
        case .export:
            schema["properties"] = [
                "items": [
                    "type": "array", "minItems": 1, "maxItems": .number(Double(ExportCommand.maxItems)),
                    "items": ["type": "string", "format": "uuid"], "description": "Video Library IDs.",
                ],
                "preset": [
                    "type": "string", "enum": .array(AgentExportPreset.allCases.map { .string($0.rawValue) }),
                ],
                "sidecar": ["type": "boolean", "description": "Also write the JSON sidecar; true when left out."],
                "wait_seconds": Self.exportWaitSchema,
            ]
            schema["required"] = ["items", "preset"]
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
                "cursor": ["type": "string", "description": "Without ids: nextCursor of the page before."],
            ]
        case .jobAction:
            schema["properties"] = [
                "action": ["type": "string", "enum": .array(AgentJobAction.allCases.map { .string($0.rawValue) })],
                "job": [
                    "type": "string", "format": "uuid", "description": "The job, for cancel, retry and run_next.",
                ],
            ]
            schema["required"] = ["action"]
        case .frames:
            schema["properties"] = [
                "item": ["type": "string", "format": "uuid", "description": "A Library item, a video or an image."],
                "file": ["type": "string", "description": "Else a video or an image on this Mac."],
                "times": [
                    "type": "array", "minItems": 1, "maxItems": .number(Double(FramesCommand.maxTimes)),
                    "items": ["type": "number", "minimum": 0], "description": "Seconds from the start, in order.",
                ],
                "compare_item": ["type": "string", "format": "uuid", "description": "Another Library item."],
                "compare_file": ["type": "string", "description": "Another video or image on this Mac."],
                "compare_source": ["type": "boolean", "description": "The item's own source clip."],
            ]
            schema["required"] = ["times"]
        case .elements:
            schema["properties"] = [
                "query": [
                    "type": "string", "maxLength": .number(Double(ElementsCommand.maxQueryLength)),
                    "description": "Words of the name.",
                ],
                "category": ["type": "string", "enum": .array(ElementsCommand.categories.map { .string($0) })],
                "limit": ["type": "integer", "minimum": 1, "maximum": .number(Double(ElementsCommand.maxLimit))],
                "cursor": ["type": "string", "description": "nextCursor of the page before."],
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
                "item": ["type": "string", "format": "uuid", "description": "A Library item ID, with sheet."],
                "sheet": [
                    "type": "string", "enum": .array(AgentSheet.allCases.map { .string($0.rawValue) }),
                    "description": "upscale_on_mac: the item's Upscale on This Mac sheet.",
                ],
            ]
        }
        return schema
    }

    private static let titleSchema: JSONValue = [
        "type": "string", "maxLength": .number(Double(AgentVideoRequest.maxTitleLength)),
        "description": "What the Queue, the Library and file names call it; the first 80 characters, on one line.",
    ]

    private static let promptSchema: JSONValue = [
        "type": "string", "maxLength": .number(Double(AgentVideoRequest.maxPromptLength)),
    ]

    private static let exportWaitSchema: JSONValue = [
        "type": "integer", "minimum": 0, "maximum": .number(Double(JobsCommand.maxWaitSeconds)),
        "description": "Wait up to this long for the export to finish before answering; it runs on either way.",
    ]

    /// The source clip's range, and for `create_video` its file.
    private static func sourceProperties(files: Bool) -> [String: JSONValue] {
        var source: [String: JSONValue] = [
            "start": [
                "type": "number", "minimum": 0, "maximum": .number(AgentSource.maxSeconds),
                "description": "Seconds from the start of the file.",
            ],
            "end": [
                "type": "number", "minimum": 0, "maximum": .number(AgentSource.maxSeconds),
                "description": "Where the job's range ends, in seconds.",
            ],
        ]
        if files { source["path"] = ["type": "string", "description": "The clip on this Mac."] }
        return source
    }

    /// The video fields of `quote` and `create_video`; `files` for paths to send, else counts and lengths only.
    private static func videoProperties(files: Bool) -> [String: JSONValue] {
        var properties: [String: JSONValue] = [
            "mode": ["type": "string", "enum": .array(AgentVideoRequest.modes.map { .string($0) })],
            "model": [
                "type": "string", "description": "A model ID from capabilities; the mode's default if left out.",
            ],
            "prompt": Self.promptSchema,
            "source": [
                "type": "object", "additionalProperties": false, "properties": .object(sourceProperties(files: files)),
                "description": files
                    ? "The source clip; left out, a model that can makes the clip from the prompt and images."
                    : "The source clip's range; end is needed.",
            ],
            // No maxItems: the limit is the model's in its mode, which capabilities and quote give.
            "images": [
                "type": "array", "items": ["type": "string"],
                "description": "Reference images on this Mac, in order, up to the model's maxImages (quote).",
            ],
            "style": ["type": "string", "format": "uuid", "description": "Restyle's style ID."],
            "resolution": ["type": "string", "description": "One from capabilities, such as 720p."],
            "draft": ["type": "boolean", "description": "A cheaper lower-resolution preview, on models with drafts."],
            "length": [
                "type": "number", "exclusiveMinimum": 0, "maximum": .number(AgentVideoRequest.maxLength),
                "description": "Seconds a clip without a source runs, or extend adds.",
            ],
            "aspect_ratio": [
                "type": "string",
                "description": "A clip without a source: 16:9, 9:16, 1:1…; with one it keeps the source's orientation.",
            ],
            "audio": ["type": "string", "enum": .array(AgentVideoRequest.audioOptions.map { .string($0) })],
            "variants": [
                "type": "integer", "minimum": 1, "maximum": .number(Double(AgentVideoRequest.maxVariants)),
                "description": "Videos one submit makes, up to quote's maxVariants.",
            ],
            "elements": [
                "type": "array", "maxItems": .number(Double(AgentElementNames.maxNames)),
                "items": ["type": "string", "maxLength": .number(Double(AgentElementNames.maxNameLength))],
                "description": "The account's elements by name, from the elements tool; their images go first.",
            ],
        ]
        if files {
            properties["title"] = titleSchema
        } else {
            properties["image_count"] = [
                "type": "integer", "minimum": 0, "maximum": .number(Double(AgentVideoRequest.protocolMaxImages)),
                "description": "How many reference images there will be.",
            ]
        }
        return properties
    }

    private var annotations: JSONValue {
        switch self {
        case .capabilities, .quote, .jobs, .libraryGet:
            ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        // Reads the account's elements on Higgsfield.
        case .elements:
            ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]
        // refresh_higgsfield reads the account's history from Higgsfield.
        case .librarySearch:
            ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]
        // Adds files to the Library from Higgsfield; one downloaded already is left as it is.
        case .libraryDownload:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]
        // Spends, but the same request_id never queues twice; it reaches Higgsfield.
        case .createVideo, .createImage, .enhance:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]
        // Cancel stops a job, retry may queue another attempt.
        case .jobAction:
            ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true]
        // The same marks again change nothing; a star may also like the result on Higgsfield.
        case .libraryMark:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]
        // Writes new files on this Mac, never over one; each call writes new ones.
        case .deliverySet, .export:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
        // Writes new files on this Mac likewise; compare_source may read a history item's source from Higgsfield.
        case .frames:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true]
        // Changes what the window shows, nothing else.
        case .show:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        }
    }
}
