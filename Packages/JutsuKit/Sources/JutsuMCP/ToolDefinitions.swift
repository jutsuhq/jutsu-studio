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
        case .jobs: "Jobs"
        case .jobAction: "Act on a job or the queue"
        case .librarySearch: "Search the Library"
        case .libraryMark: "Keep, reject or star"
        case .enhance: "Enhance a video"
        case .deliverySet: "Delivery sets"
        case .export: "Export for editing"
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
            not answered yet, remaining, and unlimitedAllowed, whether the person lets agents use the plan's unlimited \
            generations, false for the rest of the day once one was charged anyway) and the tool groups this version \
            offers. models: true adds the video models \
            (id, title, modes, resolutions, whether the connection runs it); model: an ID returns only that one, with \
            its limits per mode (seconds, images, whether it needs a style or a source). image_models: true adds the \
            image models create_image takes (counts, aspect ratios, whether an input image is needed), styles: true \
            Restyle's style IDs, voices: true Change Voice's voices. Free, and never shows a credential.
            """
        case .quote:
            """
            What a video would cost now, with the same parameters as create_video, without uploading or queueing \
            anything: the price in whole usd_cents or credits (null when not known before upload), whether it is \
            exact, what is left of today's agent budget, paysUnlimited (the plan's unlimited generations would pay \
            for it: it costs the budget nothing, and waits for the person unless unlimitedAllowed), and blocker, \
            why create_video would hold or refuse it now. A source \
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
            confirms it in the app; so does a job the plan's unlimited generations would pay for while the person \
            doesn't let agents use them (hold unlimited_not_allowed). Files (source.path, images) are paths on this Mac, copied into the app. Returns \
            the job; follow it with jobs.
            """
        case .createImage:
            """
            Makes images in Jutsu Studio, built exactly as the Image side of Create would: model (an ID from \
            capabilities with image_models; the first when left out), prompt, aspect_ratio, count, and input, an \
            image on this Mac to edit for models that take one. request_id and max_cost work as in create_video: the \
            same request_id with the same parameters returns the same request and never pays twice. Right before it \
            is sent, a price above max_cost, above what is left of the daily agent budget, over the person's daily \
            cap or not known holds it (state paused, needsPerson) until the person sends it from the Queue. Follow \
            it with jobs: results lists the images' paths once they are saved in Library › Images.
            """
        case .jobs:
            """
            One place to follow work: video jobs, image requests and exports, by ID (ids, up to 20), or the latest \
            agents started (limit, up to 50, newest first; pass nextCursor back as cursor for the page after). Each \
            has kind (video, image, export, delivery_export), state, pauseReason, hold, needsPerson, progress, \
            price, error and result (the finished video's path); an image request's results are its images' paths, \
            an export's results the files written, with folder and files (each done, failed or skipped). An ID \
            Jutsu Studio doesn't know is state unknown with next: an export's ID is forgotten when the app quits. \
            wait_seconds (0–50) waits until everything named has settled (done, failed, rejected, canceled, paused \
            or unknown); a wait that runs out returns the state as it is, with timedOut, and stops nothing. Read-only.
            """
        case .jobAction:
            """
            cancel, retry or run_next a job an agent queued (job: its ID), or pause_queue or resume_queue for every \
            job agents queued that isn't sent yet; the person's own jobs are never touched. retry is refused when \
            the job may already have been charged or its files are gone; resume_queue resumes only what pause_queue \
            paused, never the person's own Pause all or a job paused for its price or the agent limits, which only \
            the person can lift. An image request can only be canceled. Nothing is deleted.
            """
        case .librarySearch:
            """
            Finds results in the Library on this Mac, videos and images, newest first: query (words of the prompt or \
            title), kind (all, video, image), starred, verdict (unreviewed, kept, rejected), model, mode (videos \
            only), from and to (ISO 8601). Rejected results stay out unless verdict is rejected or \
            include_rejected is true. Each item has its ID, file path, kind, model, mode, aspect ratio, duration, \
            price, verdict, star, date, prompt (cut to 200 characters, promptTruncated) and version. limit up to 50; \
            pass nextCursor back as cursor for the next page. Read-only.
            """
        case .libraryMark:
            """
            Sets the culling verdict (keep, reject or clear) and, apart from it, the star (true or false) of up to \
            100 Library items by ID, as the Library's own buttons do. A star on a result the connected account made \
            is also its like on Higgsfield. Marking the same way again changes nothing (changed counts what did). \
            Reject only hides a result in the Library: nothing is deleted or moved to the Trash.
            """
        case .enhance:
            """
            Queues one Enhance operation on a video result, as the Library's Enhance menu does: upscale (target \
            1080p, 2k or 4k; frame_rate 24, 30 or 60; engine standard), reframe (aspect_ratio 9:16, 1:1 or 16:9, \
            results up to a minute), remove_background, dub (language, an ISO 639-3 code) or change_voice (voice, \
            from capabilities with voices). Needs a Higgsfield account. request_id and max_cost work as in \
            create_video, and the job is checked by the same spending guard; one whose price isn't known waits for \
            the person. A Topaz upscale is refused (priced_after_run): its price is known only after it runs. \
            Returns the job; follow it with jobs.
            """
        case .deliverySet:
            """
            Library › Delivery Sets. create: a set of Library items (items, their IDs) at their current versions, \
            with an optional name. list: every set, and folders, the folders the person exported sets to. export: \
            writes the set's files still to write with its outputs (a full-size JPEG for images and an H.264 file \
            for videos unless the person changed them) into folder, one of list's folders, or else the output \
            folder's Exports folder. The export runs in the app: it answers at once, or once it finished within \
            wait_seconds (0–50), with job (kind delivery_export), whose ID jobs follows until every file is done, \
            failed or skipped. A wait that runs out stops nothing. Free and local; never replaces a file. \
            Exporting freezes the set's versions.
            """
        case .export:
            """
            Exports video results for editing, as the result page's Export for Editing does: preset premiere, \
            davinci_resolve or final_cut_pro (ProRes 422, MOV) or editing_h264, with a JSON sidecar of the job \
            unless sidecar is false, into the output folder's Exports folder. The export runs in the app: it \
            answers at once, or once it finished within wait_seconds (0–50), with job (kind export), whose ID jobs \
            follows with progress and each file's path, or why it failed or was skipped. A wait that runs out stops \
            nothing. Free and local; never replaces a file.
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
            schema["properties"] = .object(properties)
            schema["required"] = ["request_id", "mode", "max_cost"]
        case .createImage:
            schema["properties"] = [
                "request_id": Self.requestIDSchema, "max_cost": Self.maxCostSchema,
                "model": ["type": "string", "description": "An image model ID from capabilities."],
                "prompt": ["type": "string", "maxLength": 10_000],
                "aspect_ratio": ["type": "string", "description": "One the model takes: 1:1, 16:9, 9:16…"],
                "count": [
                    "type": "integer", "minimum": 1, "maximum": .number(Double(AgentImageRequest.maxCount)),
                    "description": "Images to make, one the model offers; 1 when left out.",
                ],
                "input": ["type": "string", "description": "An image on this Mac to edit, for models that take one."],
            ]
            schema["required"] = ["request_id", "prompt", "max_cost"]
        case .librarySearch:
            schema["properties"] = [
                "query": ["type": "string", "maxLength": 500],
                "kind": ["type": "string", "enum": .array(AgentLibraryKind.allCases.map { .string($0.rawValue) })],
                "starred": ["type": "boolean"],
                "verdict": ["type": "string", "enum": .array(AgentVerdict.allCases.map { .string($0.rawValue) })],
                "include_rejected": ["type": "boolean"],
                "model": ["type": "string", "description": "A video model ID or an image model's name."],
                "mode": ["type": "string", "enum": .array(AgentVideoRequest.modes.map { .string($0) })],
                "from": ["type": "string", "format": "date-time"],
                "to": ["type": "string", "format": "date-time"],
                "limit": ["type": "integer", "minimum": 1, "maximum": .number(Double(LibrarySearchCommand.maxLimit))],
                "cursor": ["type": "string", "description": "nextCursor of the page before."],
            ]
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
            schema["properties"] = [
                "request_id": Self.requestIDSchema, "max_cost": Self.maxCostSchema,
                "item": ["type": "string", "format": "uuid", "description": "A video's Library ID."],
                "operation": [
                    "type": "string", "enum": .array(AgentEnhancement.allCases.map { .string($0.rawValue) }),
                ],
                "target": ["type": "string", "enum": ["1080p", "2k", "4k"]],
                "frame_rate": ["type": "integer", "enum": [24, 30, 60]],
                "engine": ["type": "string", "enum": ["standard"]],
                "aspect_ratio": ["type": "string", "enum": ["9:16", "1:1", "16:9"]],
                "language": ["type": "string", "description": "An ISO 639-3 code, such as fra."],
                "voice": ["type": "string", "description": "A voice ID from capabilities."],
            ]
            schema["required"] = ["request_id", "item", "operation", "max_cost"]
        case .deliverySet:
            schema["properties"] = [
                "action": [
                    "type": "string", "enum": .array(AgentDeliveryAction.allCases.map { .string($0.rawValue) }),
                ],
                "name": ["type": "string", "maxLength": 120, "description": "create: the set's name."],
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

    private static let exportWaitSchema: JSONValue = [
        "type": "integer", "minimum": 0, "maximum": .number(Double(JobsCommand.maxWaitSeconds)),
        "description": "Wait up to this long for the export to finish before answering; it runs on either way.",
    ]

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

    private var annotations: JSONValue {
        switch self {
        case .capabilities, .quote, .jobs, .librarySearch:
            ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
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
        // Changes what the window shows, nothing else.
        case .show:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        }
    }
}
