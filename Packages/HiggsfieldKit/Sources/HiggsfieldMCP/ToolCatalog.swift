import Foundation

// The server's tool contract: Genjutsu runs through the generic `generate_video` tool, inputs go up through
// `media_upload` and `media_confirm`, and jobs are read with `job_status`. No tool cancels a generation. Seedance
// 2.5 and Kling 3.0 Motion Control take the same reference video and images as Genjutsu. Genjutsu's galleries
// and styles are `get_presets` and `execute_preset` (GenjutsuCatalog.swift).

/// What `HiggsfieldAccount` needs a tool for, by the tool's exact name.
enum ToolRole: String, CaseIterable, Sendable {
    case generate = "generate_video"
    case upload = "media_upload"
    case confirmUpload = "media_confirm"
    case status = "job_status"
    case balance
    case generations = "show_generations"
    case presets = "get_presets"
    case executePreset = "execute_preset"
    case like = "set_generation_like"
    case transactions
    case assets = "assets_picker_list"
    case modelsExplore = "models_explore"
    /// `jobs: [{job_id, index}]` per the catalog snapshot of 2026-10-15 (`HiggsfieldAccount.waitForJobs`).
    case jobsWait = "jobs_wait"
    /// Operations on a result (`VideoEdit`) and the voices they take (`VoiceList.swift`), as the catalog snapshot of
    /// 2026-10-15 states them.
    case upscaleVideo = "upscale_video"
    case removeBackground = "remove_background"
    case reframe
    case dubbing
    case voiceChange = "voice_change"
    case listVoices = "list_voices"
    /// `{params: {model, prompt, count, aspect_ratio, medias, get_cost, use_unlim}}` (`AccountImageRequest`).
    case generateImage = "generate_image"
    /// `list`, `get` and `create` of the account's elements (`ReferenceElements.swift`).
    case referenceElements = "show_reference_elements"
    /// AI Influencer character sheets (`CharacterSheets.swift`): the traits, the presets, the free quote and the
    /// paid submit.
    case influencerOptions = "ai_influencer_get_options"
    case influencerPresets = "ai_influencer_list_presets"
    case influencerPrepare = "ai_influencer_prepare"
    case influencerGenerate = "ai_influencer_generate"
    /// `{action: "create", params: {model, medias}}` (`Virality.swift`).
    case viralityPredictor = "virality_predictor"
    /// `url` and `type` in, a confirmed `media_id` out (`HiggsfieldAccount.importMedia`).
    case importMedia = "media_import_url"

    /// Top-level arguments the tool's `inputSchema` must declare; otherwise its role counts as unavailable.
    var requiredArguments: Set<String> {
        switch self {
        case .generate: [ToolKey.params]
        case .upload: [ToolKey.filename, ToolKey.contentType]
        case .confirmUpload: [ToolKey.mediaID, ToolKey.type]
        case .status: [ToolKey.jobID]
        case .balance: []
        case .generations: [ToolKey.size, ToolKey.cursor]
        case .presets: [ToolKey.source, ToolKey.category, ToolKey.presetID, ToolKey.initialInputs, ToolKey.cursor]
        case .executePreset: [ToolKey.source, ToolKey.presetID, ToolKey.inputs]
        case .like: [ToolKey.jobIDSingle, ToolKey.liked]
        case .transactions: [ToolKey.cursor, ToolKey.size]
        case .assets: [ToolKey.source, ToolKey.kind, ToolKey.cursor, ToolKey.size]
        case .modelsExplore: [ToolKey.action, ToolKey.type]
        case .jobsWait: [ToolKey.jobs]
        case .upscaleVideo, .removeBackground, .reframe, .dubbing, .voiceChange, .generateImage: [ToolKey.params]
        case .listVoices: [ToolKey.cursor, ToolKey.size]
        case .referenceElements: [ToolKey.action, ToolKey.elementID, ToolKey.cursor, ToolKey.size]
        case .influencerOptions: [ToolKey.tier]
        case .influencerPresets: [ToolKey.cursor, ToolKey.size]
        case .influencerPrepare:
            [
                ToolKey.tier, ToolKey.selection, ToolKey.brief, ToolKey.seed, ToolKey.batchSize, ToolKey.medias,
                ToolKey.itemMedias, ToolKey.randomize,
            ]
        case .influencerGenerate: [ToolKey.params, ToolKey.maxCredits]
        case .viralityPredictor: [ToolKey.action, ToolKey.params]
        case .importMedia: [ToolKey.url, ToolKey.type]
        }
    }

    /// Every one of these is needed to run a job.
    static let generation: [ToolRole] = [.generate, .upload, .confirmUpload, .status]
    /// Every one of these is needed to run a Genjutsu Style.
    static let styles: [ToolRole] = [.presets, .executePreset, .upload, .confirmUpload, .status]

    /// These calls may charge before an execution error is returned.
    var mayStartGeneration: Bool {
        switch self {
        case .generate, .generateImage, .executePreset, .upscaleVideo, .removeBackground, .reframe, .dubbing,
            .voiceChange, .viralityPredictor, .influencerGenerate:
            true
        default: false
        }
    }

    /// Polls of a job that may already be paid: an answer that can't be read is retried, never taken as the end.
    var readsJobStatus: Bool {
        switch self {
        case .status, .jobsWait: true
        default: false
        }
    }
}

/// Argument and result keys, as the server names them.
enum ToolKey {
    static let params = "params"
    static let model = "model"
    static let medias = "medias"
    static let role = "role"
    static let value = "value"
    static let resolution = "resolution"
    static let mode = "mode"
    static let duration = "duration"
    static let generateAudio = "generate_audio"
    static let aspectRatio = "aspect_ratio"
    static let bitrateMode = "bitrate_mode"
    static let extensionMode = "extension_mode"
    static let draft = "draft"
    static let draftJobID = "draft_job_id"
    static let prompt = "prompt"
    static let getCost = "get_cost"
    static let useUnlim = "use_unlim"
    static let filename = "filename"
    static let contentType = "content_type"
    static let uploads = "uploads"
    static let uploadURL = "upload_url"
    static let mediaID = "media_id"
    static let type = "type"
    static let url = "url"
    static let jobID = "jobId"
    static let results = "results"
    static let id = "id"
    static let generation = "generation"
    static let status = "status"
    static let rawURL = "rawUrl"
    static let error = "error"
    static let cost = "cost"
    static let credits = "credits"
    static let creditsExact = "credits_exact"
    static let plan = "subscription_plan_type"
    static let requestID = "request_id"
    static let onlyCompleted = "only_completed"
    static let size = "size"
    static let cursor = "cursor"
    static let items = "items"
    static let nextCursor = "next_cursor"
    /// `models_explore`'s paging: the answer's `has_more` and `next_page_token`, sent back as `after`.
    static let hasMore = "has_more"
    static let nextPageToken = "next_page_token"
    static let after = "after"
    static let createdAt = "createdAt"
    static let liked = "liked"
    static let width = "width"
    static let height = "height"
    static let data = "data"
    static let source = "source"
    static let category = "category"
    static let limit = "limit"
    static let presetID = "preset_id"
    static let initialInputs = "initial_inputs"
    static let inputs = "inputs"
    static let name = "name"
    static let description = "description"
    static let thumbnailURL = "thumbnail_url"
    static let previewURL = "preview_url"
    static let video = "video"
    static let references = "references"
    static let execution = "execution"
    static let costCredits = "cost_credits"
    static let jobIDs = "job_ids"
    static let jobIDSingle = "job_id"
    static let jobs = "jobs"
    static let index = "index"
    static let genjutsu = "genjutsu"
    static let notice = "notice"
    static let message = "message"
    static let retryLiteral = "retry_literal_with"
    static let declinedPresetID = "declined_preset_id"
    static let all = "all"
    static let kind = "kind"
    static let thumbnailURLCamel = "thumbnailUrl"
    static let createdAtSnake = "created_at"
    static let displayName = "display_name"
    static let action = "action"
    static let backgroundSource = "background_source"
    static let modelsExplore = "models_explore"
    static let modelID = "model_id"
    static let list = "list"
    static let get = "get"
    static let models = "models"
    static let modelIDs = [id, modelID, model]
    static let supportsUnlim = "supports_unlim"
    static let unlim = "unlim"
    static let pollAfterSeconds = "poll_after_seconds"
    static let provider = "provider"
    static let fps = "fps"
    static let mediaType = "media_type"
    static let videoID = "video_id"
    static let targetLanguage = "target_language"
    static let voiceID = "voice_id"
    static let voiceType = "voice_type"
    static let durationSeconds = "duration_seconds"
    static let count = "count"
    static let elementID = "element_id"
    static let element = "element"
    static let create = "create"
    static let auto = "auto"
    static let mediaInput = "media_input"
    static let tier = "tier"
    static let tiers = "tiers"
    static let selection = "selection"
    static let brief = "brief"
    static let seed = "seed"
    static let batchSize = "batch_size"
    static let itemMedias = "item_medias"
    static let randomize = "randomize"
    static let maxCredits = "max_credits"
    static let freeGensRemaining = "free_gens_remaining"
    static let submitted = "submitted"
    static let groups = "groups"
    static let options = "options"
    static let label = "label"
    static let max = "max"
    static let preview = "preview"
    static let sheet = "sheet"
    static let recreate = "recreate"
    static let recreateUnavailableReason = "recreate_unavailable_reason"
    static let influencer = "influencer"
    static let image = "image"
    static let title = "title"
}

/// The server's tools, each matched to its role by name and schema.
struct ToolCatalog: Sendable {
    private let tools: [ToolRole: MCPTool]

    init(_ available: [MCPTool]) {
        var tools: [ToolRole: MCPTool] = [:]
        for role in ToolRole.allCases {
            tools[role] = available.first {
                $0.name == role.rawValue && role.requiredArguments.isSubset(of: $0.argumentNames)
            }
        }
        self.tools = tools
    }

    subscript(role: ToolRole) -> MCPTool? { tools[role] }

    /// Every tool a job needs is there.
    var canGenerate: Bool {
        ToolRole.generation.allSatisfy { tools[$0] != nil }
    }

    var canRunStyles: Bool {
        ToolRole.styles.allSatisfy { tools[$0] != nil }
    }
}
