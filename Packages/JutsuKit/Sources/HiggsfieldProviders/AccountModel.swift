import HiggsfieldMCP
import JutsuCore

/// The `generate_video` request of each job, and its price.
enum AccountModel {
    /// The modes `generate_video` runs; Restyle runs as a Genjutsu Style (`HiggsfieldMCPProvider`).
    static let genjutsuModes: Set<Mode> = [.motionTransfer, .objectSwap]

    static let generateModes: Set<Mode> = genjutsuModes.union([.edit, .extend])

    /// What an operation works on: the uploaded source when there is one, else the parent's account job ID; `nil`
    /// with neither.
    static func editInput(for spec: JobSpec, inputs: RemoteInputs) -> VideoEdit.Input? {
        if let media = inputs.video?.id { return .media(media) }
        return spec.operation?.sourceJobID.map { .job($0) }
    }

    /// The tool call of an operation spec; `nil` for a generation, and for one the tool can't take: Topaz at 2K, the
    /// standard upscaler without the source's size, a reframe of a result longer than a minute or of unknown length.
    static func editOperation(for spec: JobSpec) -> VideoEdit.Operation? {
        guard let operation = spec.operation else { return nil }
        switch operation.action {
        case .upscale(let options):
            return upscale(options, size: spec.source?.pixelSize)
        case .removeBackground:
            return .removeBackground
        case .reframe(let aspect):
            let length = sourceLength(of: spec)
            guard length > 0, length <= ReframeAspect.maxSourceLength else { return nil }
            // `reframe` takes 480p, 720p or 1080p: a MiniMax result's 768p or 2K goes as the nearest.
            return .reframe(
                aspectRatio: aspect.rawValue, durationSeconds: length,
                resolution: spec.resolution.standardized.rawValue)
        case .dub(let language):
            return .dub(language: language.rawValue)
        case .changeVoice(let voice):
            return .changeVoice(voiceID: voice.id, voiceType: voice.type)
        }
    }

    /// The length an operation works on: the source's range, else the parent result's length.
    static func sourceLength(of spec: JobSpec) -> Double {
        spec.source.map { $0.range.upperBound - $0.range.lowerBound } ?? spec.duration
    }

    /// `upscale_video` per its schema: `bytedance` takes "1080p", "2k" or "4k", needs the source's size and takes a
    /// frame rate (left out for the server's 24 fps); `topaz` takes "1080p" or "2160p" and neither.
    private static func upscale(_ options: UpscaleOptions, size: PixelSize?) -> VideoEdit.Operation? {
        switch options.engine {
        case .standard:
            guard let size, size.width > 0, size.height > 0 else { return nil }
            return .upscale(
                resolution: options.target.rawValue,
                fps: options.frameRate == .keep ? nil : options.frameRate.rawValue, provider: .bytedance,
                width: size.width, height: size.height)
        case .topaz:
            let resolution: String? =
                switch options.target {
                case .p1080: "1080p"
                case .k4: "2160p"
                case .k2: nil
                }
            return resolution.map { .upscale(resolution: $0, fps: nil, provider: .topaz, width: nil, height: nil) }
        }
    }

    /// The model parameters the account sends.
    static let parameters: Set<ModelParameter> = [.seedanceBitrate, .seedanceFrames, .klingVideoBackground]

    /// `nil` for a job the account connection can't run: the catalog names no `generate_video` model for its model
    /// and mode (Genjutsu's Restyle runs as a Style), or one this client doesn't know.
    static func model(for spec: JobSpec) -> VideoRequest.Model? {
        guard spec.model.serves(spec.mode) else { return nil }
        return spec.model.accountModelID(for: spec.mode).map(VideoRequest.Model.init(rawValue:))
    }

    /// Whether `generate_video` runs `model` in any mode; the others are API key only.
    static func runs(_ model: VideoModel) -> Bool {
        model.modes.contains { model.accountModelID(for: $0) != nil }
    }

    /// Every `generate_video` model the catalog names, once each, in its order: what `models_explore` is asked
    /// about for limits and the unlimited allowance.
    static let accountModels: [VideoRequest.Model] = {
        var seen: Set<String> = []
        return VideoModel.allCases.flatMap { model in model.modes.compactMap(model.accountModelID(for:)) }
            .filter { seen.insert($0).inserted }.map(VideoRequest.Model.init(rawValue:))
    }()

    /// The modes of each model, among `modes`, whose `generate_video` model `allowance` covers.
    static func unlimited(_ allowance: UnlimitedAllowance, modes: Set<Mode>) -> [VideoModel: Set<Mode>] {
        var unlimited: [VideoModel: Set<Mode>] = [:]
        for model in VideoModel.allCases {
            let covered = modes.filter { mode in
                let spec = JobSpec(mode: mode, model: model, source: nil, resolution: .p720)
                return Self.model(for: spec).map(allowance.covers) == true
            }
            if !covered.isEmpty { unlimited[model] = covered }
        }
        return unlimited
    }

    /// Seedance's `aspect_ratio` outside frames, edit and extend: without a source the one asked for, or `auto`;
    /// with one, the source's own shape. Sent none, a 576×1024 source made a 1280×720 clip (an agent's job, issue
    /// #22), as a start frame did. Whether the server keeps to it with `video_references` isn't confirmed live; the
    /// catalog says it ignores `aspect_ratio` only for `video_edit` and `video_extension`.
    /// The source's shape is the one the API key connection asks for (`APIModel.aspectRatio`); only the frame without
    /// a source differs, as the account takes `auto` and the REST schema doesn't.
    static func seedanceFrame(of spec: JobSpec) -> String? {
        guard spec.source != nil else { return (spec.aspectRatio ?? .auto).rawValue }
        return APIModel.aspectRatio(of: spec)?.rawValue
    }

    /// Seedance and Kling make a clip as long as the source selection. Without a source, Seedance makes one as long
    /// and in the frame the job asks for, from the prompt alone (`t2v`) or with the images as references; it then
    /// makes the soundtrack too, unless the job is muted. With a source it makes one only when asked to
    /// (`AudioOption.generated`); otherwise the source's sound is put back after download. It keeps the source's
    /// frame (`seedanceFrame`).
    static func request(
        for spec: JobSpec, model: VideoRequest.Model, media: [VideoRequest.Media],
        parameters: Set<ModelParameter> = AccountModel.parameters, constraints: ModelConstraintTable = .builtIn
    ) -> VideoRequest {
        if let draftJobID = spec.draftJobID, model == .seedance25 { return .finalize(draftJobID: draftJobID) }
        var request = VideoRequest(model: model, media: media, prompt: spec.prompt)
        switch spec.model.descriptor.shape {
        case .genjutsu:
            request.resolution = spec.resolution.rawValue
        case .seedance:
            request.resolution = spec.resolution.rawValue
            request.generateAudio = generatesAudio(spec)
            if parameters.contains(.seedanceBitrate) { request.bitrateMode = spec.bitrate?.rawValue }
            switch spec.mode {
            case .edit:
                // The output follows the source, as on REST: no length.
                request.mode = VideoRequest.seedanceEdit
            case .extend:
                // The output's frame follows the clip.
                request.mode = VideoRequest.seedanceExtend
                request.extensionMode = VideoRequest.extendForward
                request.duration = Double(durationSeconds(of: spec, constraints: constraints))
            default:
                request.duration = Double(durationSeconds(of: spec, constraints: constraints))
                if spec.usesFrames {
                    // The server doesn't take the frame from the start image: without `aspect_ratio` a 9:16 start
                    // frame made a 16:9 clip (live, 2026-10-15). The engine sets the start frame's shape when the
                    // job is queued (`JobEngine.insert`).
                    request.mode = VideoRequest.omniReference
                    request.aspectRatio = spec.aspectRatio?.rawValue
                    request.media = asFrames(media)
                } else {
                    request.mode = media.isEmpty ? VideoRequest.textToVideo : VideoRequest.omniReference
                    request.aspectRatio = seedanceFrame(of: spec)
                }
                request.draft = sendsNativeDraft(spec, model: model)
            }
        case .klingMotionControl:
            request.mode = klingMode(spec.resolution)
            request.duration = Double(durationSeconds(of: spec, constraints: constraints))
            if spec.keepsVideoBackground { request.backgroundSource = VideoRequest.backgroundFromVideo }
        case .klingVideoReference:
            request.mode = klingMode(spec.resolution)
            request.duration = Double(durationSeconds(of: spec, constraints: constraints))
        case .klingVideoEdit:
            // The output follows the source, as on REST: no length.
            request.mode = klingMode(spec.resolution)
        case .wanReference:
            // No `mode`: Wan and MiniMax read the job from the media roles.
            request.resolution = spec.resolution.rawValue
            request.duration = Double(durationSeconds(of: spec, constraints: constraints))
            if spec.model.declares(.generatedAudio) { request.generateAudio = generatesAudio(spec) }
        case .cinemaStudio:
            // The output's frame follows the reference video. The creative controls aren't sent: the account takes
            // them as `*_id`s its catalog doesn't list (`ModelParameter.cinemaControls`).
            request.mode = VideoRequest.omniReference
            request.resolution = spec.resolution.rawValue
            request.duration = Double(durationSeconds(of: spec, constraints: constraints))
            request.generateAudio = generatesAudio(spec)
        case .kling4:
            kling4(&request, spec: spec, constraints: constraints)
        }
        return request
    }

    /// The first two media as a start and an end frame.
    static func asFrames(_ media: [VideoRequest.Media]) -> [VideoRequest.Media] {
        zip(media, [MediaRole.startFrame, .endFrame]).map { item, role in VideoRequest.Media(role: role, id: item.id) }
    }

    /// Kling 4.0's `kling4_0` settings: the resolution, the length, the frame and the `mode`, with frames as
    /// `start_image` and `end_image`.
    static func kling4(_ request: inout VideoRequest, spec: JobSpec, constraints: ModelConstraintTable) {
        request.resolution = spec.resolution.rawValue
        request.duration = Double(durationSeconds(of: spec, constraints: constraints))
        request.aspectRatio = kling4Frame(of: spec, auto: AspectRatio.auto.rawValue)
        request.mode = kling4Mode(of: spec)
        if spec.usesFrames { request.media = asFrames(request.media) }
    }

    /// Kling 4.0's `mode` (`kling4_0`, catalog snapshot of 2026-10-28), as REST's endpoint is picked
    /// (`VideoModel.endpointID`): Edit, frames, references (a source or images), else the prompt alone.
    static func kling4Mode(of spec: JobSpec) -> String {
        if spec.mode == .edit { return VideoRequest.kling4VideoEdit }
        if spec.usesFrames { return VideoRequest.kling4ImageToVideo }
        return spec.source == nil && spec.references.isEmpty
            ? VideoRequest.kling4TextToVideo : VideoRequest.kling4ReferenceToVideo
    }

    /// Kling 4.0's `aspect_ratio` on either connection: `auto` (REST's `adaptive`, the account's `auto`), which
    /// follows the references, for a job with a source and for Auto; otherwise the model's fixed frame
    /// (`models.json` `aspectRatios`) nearest the one asked for, as no Kling 4.0 schema has 4:3 or 3:4. A clip from
    /// frames is asked for its start frame's shape, set when the job is queued (`JobEngine.insert`). `nil` for `auto`
    /// leaves the field out (REST's text-to-video, which has no `adaptive` and defaults to 16:9).
    static func kling4Frame(of spec: JobSpec, auto: String?) -> String? {
        guard spec.source == nil, let shape = spec.aspectRatio?.widthOverHeight else { return auto }
        let size = PixelSize(width: Int((shape * 10_000).rounded()), height: 10_000)
        return AspectRatio.nearest(to: size, among: spec.model.descriptor.aspectRatios)?.rawValue ?? auto
    }

    /// Whether Draft asks for Seedance 2.5's native draft (`draft: true`): a 480p draft of a generation, which the
    /// account can finalize at 1080p within seven days (`VideoRequest.finalize`). `models_explore get` of
    /// `seedance_2_5` describes `draft` as "Generate a 480p draft that can be finalized within seven days"; it was
    /// seen live with `omni_reference` on 2026-10-15, priced and charged 45 credits for 15 s like the same request
    /// without it. Edit and Extend, and a draft at another resolution, stay plain renders.
    static func sendsNativeDraft(_ spec: JobSpec, model: VideoRequest.Model) -> Bool {
        spec.isDraft && spec.draftJobID == nil && model == .seedance25 && spec.resolution == .p480
            && !spec.mode.isVideoOperation && spec.operation == nil
    }

    /// The share of a fresh 1080p render's price that finalizing a draft costs: the fallback when the finalize
    /// can't be quoted. From `get_cost` on 2026-10-15: finalizing a 15 s draft quoted 80 credits, the same 15 s at
    /// 1080p 240.
    static let finalizeShare = 1.0 / 3

    /// Whether the model makes the soundtrack (Seedance, Wan 3.0, Cinema Studio), on either connection: always
    /// without a source and for the part Extend adds, which no source sound belongs to, unless the job is muted; with
    /// a source only when asked to.
    static func generatesAudio(_ spec: JobSpec) -> Bool {
        if spec.audio == .mute { return false }
        return spec.source == nil || spec.mode == .extend || spec.audio == .generated
    }

    /// Whether Kling keeps the motion video's sound on the server, with an API key (the account's model has no such
    /// parameter, so its sound is handled after download). Only for `original`, which
    /// saves putting it back after download: a muted job wants none, and Fade out comes back silent so the faded
    /// source sound is put on it after download (`AudioPlan` keeps any sound a result already has).
    static func keepsOriginalSound(_ spec: JobSpec) -> Bool { spec.audio == .original }

    /// The billed seconds of the selection, or of the length asked for (for Extend, the part it adds), inside the
    /// model's duration limits (by `constraints` where they say).
    static func durationSeconds(of spec: JobSpec, constraints: ModelConstraintTable = .builtIn) -> Int {
        let limits = spec.limits(in: constraints).duration
        let seconds = Pricing.billedSeconds(spec.duration)
        return min(max(seconds, Int(limits.lowerBound.rounded(.up))), Int(limits.upperBound.rounded(.down)))
    }

    /// Kling has a quality mode instead of a resolution (`KlingQuality`).
    static func klingMode(_ resolution: Resolution) -> String {
        KlingQuality(resolution) == .pro ? VideoRequest.klingPro : VideoRequest.klingStandard
    }

    /// Whether the job is billed by its source rather than by a length it sends: Genjutsu's Motion Transfer and
    /// Object Swap, Seedance's Edit and Kling O3 Edit. `get_cost` prices these only with the source in `medias` (a
    /// quote without it gets 422), so they are quoted once it is uploaded.
    static func billsSource(_ spec: JobSpec) -> Bool {
        [.genjutsu, .klingVideoEdit].contains(spec.model.descriptor.shape) || spec.mode == .edit
    }

    /// Whether `get_cost` can price the job only with its media: one billed by its source (`billsSource`), and a
    /// Kling 4.0 job with a source, frames or images. A quote without media can't name its `mode` truthfully, and
    /// Higgsfield's announcement of Kling 4.0 says references may change the price, so it is quoted once uploaded.
    static func quotesAfterUpload(_ spec: JobSpec) -> Bool {
        billsSource(spec)
            || (spec.model.descriptor.shape == .kling4 && (spec.source != nil || !spec.references.isEmpty))
    }

    /// The `get_cost` question for a job before anything is uploaded: its request with no media, prompt or variants,
    /// paid in credits. Per the free quotes of 2026-10-15 (issue #113) a model sent a length is priced by that
    /// length, the resolution or Kling's `mode`, and nothing it reads from the media; Seedance's audio, bitrate and
    /// `count` don't change the quote either. `nil` for a job quoted only with its media (`quotesAfterUpload`).
    static func quoteRequest(
        for spec: JobSpec, model: VideoRequest.Model, constraints: ModelConstraintTable = .builtIn
    ) -> VideoRequest? {
        guard !quotesAfterUpload(spec) else { return nil }
        var request = request(for: spec, model: model, media: [], constraints: constraints)
        request.prompt = ""
        request.count = 1
        request.usesUnlimited = false
        // A finalize names its draft and sends no length: the draft's own is billed.
        return request.duration == nil && request.draftJobID == nil ? nil : request
    }

    /// The fallback price, by the catalog's `credits` (`VideoModelDescriptor.Credits`), from `get_cost` quotes of
    /// 2026-10-15: shown, as an estimate, only until Higgsfield quotes the job (`HiggsfieldMCPProvider.estimate`),
    /// which for a model billed by its source is after upload, or when the quote fails. Only the billed length
    /// follows `constraints`. A job billed by its source bills the selection as it is; the others bill the length
    /// they are sent (`durationSeconds`). `nil` for a model without credits at the job's resolution.
    /// The finalize of a draft (`JobSpec.draftJobID`) is `finalizeShare` of the 1080p price of its length.
    static func estimatedCredits(for spec: JobSpec, constraints: ModelConstraintTable = .builtIn) -> Int? {
        let credits = spec.model.descriptor.credits.at(spec.mode, hasSource: spec.source != nil)
        guard let rate = credits.perSecond[spec.draftJobID == nil ? spec.resolution : .p1080] else { return nil }
        let seconds =
            billsSource(spec)
            ? Pricing.billedSeconds(spec.duration) : durationSeconds(of: spec, constraints: constraints)
        let share = spec.draftJobID == nil ? 1 : finalizeShare
        return Int(((credits.base + rate * Double(seconds)) * share).rounded(.up))
    }

    /// A Genjutsu Style's price before upload, fitted to `get_presets` quotes: 1.5 credits plus 3, 7 or 11 a second
    /// at 480p, 720p and 1080p (12 s: 37.5, 85.5 and 133.5 on 2026-10-15; 8 s: 25.5, 57.5 and 89.5 on 2026-10-14).
    /// `get_presets` quotes a Style only with the uploaded video (`HiggsfieldAccount.cost(of: StyleRun)`).
    static func styleCredits(for spec: JobSpec) -> Int {
        let rate: Double = [Resolution.p480: 3, .p720: 7, .p1080: 11][spec.resolution] ?? 0
        return Int((1.5 + rate * Double(Pricing.billedSeconds(spec.duration))).rounded(.up))
    }

    /// The Jutsu model and mode each `generate_video` model runs: the catalog's first model and mode naming it.
    /// Seedance lists Motion before Edit and Extend, which have their own limits (`Mode.limits`), so a
    /// `seedance_2_5` answer, about its generation, doesn't change them.
    static let constrainedJobs: [VideoRequest.Model: (model: VideoModel, mode: Mode)] = {
        var jobs: [VideoRequest.Model: (model: VideoModel, mode: Mode)] = [:]
        for model in VideoModel.allCases {
            for mode in model.modes {
                guard let id = model.accountModelID(for: mode) else { continue }
                let server = VideoRequest.Model(rawValue: id)
                if jobs[server] == nil { jobs[server] = (model, mode) }
            }
        }
        return jobs
    }()

    /// `models_explore`'s limits as the table Create reads, in a fixed order.
    static func constraints(from limits: [VideoRequest.Model: ModelLimits]) -> ModelConstraintTable {
        ModelConstraintTable(
            entries: accountModels.compactMap { model in
                guard let read = limits[model], let job = constrainedJobs[model] else { return nil }
                return ModelConstraintTable.Entry(
                    model: job.model, mode: job.mode,
                    constraints: ModelConstraints(
                        minDuration: read.minDuration, maxDuration: read.maxDuration,
                        minReferenceImages: read.minImages, maxReferenceImages: read.maxImages))
            })
    }
}
