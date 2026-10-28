import Foundation

/// Everything needed to run one generation.
public struct JobSpec: Codable, Sendable, Hashable {
    public var mode: Mode
    /// Only Genjutsu serves every mode (`VideoModel.serves`).
    public var model: VideoModel
    /// `nil` for a clip made from the prompt and images alone (`VideoModel.makesClipsWithoutSource`).
    public var source: SourceClip?
    /// Ordered; the API keeps the order.
    public var references: [LocalImage]
    /// Restyle only.
    public var presetID: UUID?
    /// Empty when unused: the API rejects `null`.
    public var prompt: String
    /// One the model renders at in the mode (`VideoModel.resolutions(for:)`): the initializer moves another to the
    /// nearest one.
    public var resolution: Resolution
    public var isDraft: Bool
    /// Applied locally after download; the API never sees it.
    public var audio: AudioOption
    /// The source and references as the account connection already holds them, in the same order: the job
    /// sends these media IDs instead of preparing and uploading the files, and the whole source is used.
    public var remoteInputs: RemoteInputs?
    /// Kling only: the result keeps the source video's background instead of the reference image's.
    public var keepsVideoBackground: Bool
    /// Seconds a clip made without a source runs, or the seconds Extend adds; `nil` otherwise, where the source's
    /// selection sets the length.
    public var length: TimeInterval?
    /// The frame of a clip made without a source; `nil` with a source. For a clip from frames (`usesFrames`), the
    /// start frame's shape, set when the job is queued.
    public var aspectRatio: AspectRatio?
    /// Seedance only; `nil` leaves the server's default.
    public var bitrate: SeedanceBitrate?
    /// Kling only; `nil` leaves the server's default, the video's.
    public var characterOrientation: CharacterOrientation?
    /// Cinema Studio only; the director picks each control it leaves out.
    public var cinemaControls: CinemaControls
    /// Seedance without a source: `references` are the start frame and, when there are two, the end frame
    /// (`usesFrames`), rather than images to draw from.
    public var referencesAreFrames: Bool
    /// Paid from the plan's unlimited allowance (the account's `use_unlim`) rather than credits. The engine sets
    /// it when the job is queued (`GenerationProvider.paysUnlimited`) and clears it when the provider says the
    /// job cost credits after all; the daily cap leaves such a job out.
    public var usesUnlimited: Bool
    /// An operation on an existing result (`source`) rather than a generation; `nil` for a generation and in jobs
    /// stored before operations existed.
    public var operation: PostOperation?
    /// How many variants of this same request one submit makes, 1…`maximumVariants`: the account's `count`. The
    /// submit's answer becomes that many jobs, and each of them carries 1 from then on, so a retry of one makes
    /// one. 1 in jobs stored before variants existed.
    public var variants: Int
    /// Seedance on the account: the completed native draft (`RemoteJob.isNativeDraft`) this final finalizes at 1080p
    /// by its job ID (`draft_job_id`), instead of rendering the inputs again. Nothing is uploaded for it. `nil` for
    /// any other job, and in jobs stored before it existed.
    public var draftJobID: String?
    /// What the job is called in lists instead of its source's file name (`name`): an agent's `title`, trimmed and
    /// cut to `maxTitleLength` (`title(from:)`). `nil` for the person's own jobs, and in jobs stored before it existed.
    public var title: String?

    /// The most variants one submit makes (`generate_video`'s `count`).
    public static let maximumVariants = 4

    /// The jobs `specs` become once submitted: one per variant.
    public static func jobCount(_ specs: [JobSpec]) -> Int {
        specs.reduce(0) { $0 + max($1.variants, 1) }
    }

    public init(
        mode: Mode, model: VideoModel = .genjutsu, source: SourceClip?, references: [LocalImage] = [],
        presetID: UUID? = nil, prompt: String = "", resolution: Resolution, isDraft: Bool = false,
        audio: AudioOption = .original, remoteInputs: RemoteInputs? = nil, keepsVideoBackground: Bool = false,
        length: TimeInterval? = nil, aspectRatio: AspectRatio? = nil, bitrate: SeedanceBitrate? = nil,
        characterOrientation: CharacterOrientation? = nil, cinemaControls: CinemaControls = CinemaControls(),
        referencesAreFrames: Bool = false, usesUnlimited: Bool = false, operation: PostOperation? = nil,
        variants: Int = 1, draftJobID: String? = nil, title: String? = nil
    ) {
        self.mode = mode
        self.model = model
        self.source = source
        self.references = references
        self.presetID = presetID
        self.prompt = prompt
        self.resolution = model.fitted(resolution, for: mode)
        self.isDraft = isDraft
        self.audio = audio
        self.remoteInputs = remoteInputs
        self.keepsVideoBackground = keepsVideoBackground
        self.length = length
        self.aspectRatio = aspectRatio
        self.bitrate = bitrate
        self.characterOrientation = characterOrientation
        self.cinemaControls = cinemaControls
        self.referencesAreFrames = referencesAreFrames
        self.usesUnlimited = usesUnlimited
        self.operation = operation
        self.variants = variants
        self.draftJobID = draftJobID
        self.title = title
    }

    /// Jobs stored before `audio` existed decode as `.original`, before `model` as Genjutsu, before
    /// `keepsVideoBackground` with the image's background, before `referencesAreFrames` with references, and
    /// before `usesUnlimited` paid in credits, before `operation` as generations, before `variants` as one, and
    /// before `cinemaControls` with none set, and before `title` named after their source.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        model = try container.decodeIfPresent(VideoModel.self, forKey: .model) ?? .genjutsu
        source = try container.decodeIfPresent(SourceClip.self, forKey: .source)
        references = try container.decode([LocalImage].self, forKey: .references)
        presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
        prompt = try container.decode(String.self, forKey: .prompt)
        let resolution = try container.decode(Resolution.self, forKey: .resolution)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        audio = try container.decodeIfPresent(AudioOption.self, forKey: .audio) ?? .original
        remoteInputs = try container.decodeIfPresent(RemoteInputs.self, forKey: .remoteInputs)
        keepsVideoBackground = try container.decodeIfPresent(Bool.self, forKey: .keepsVideoBackground) ?? false
        length = try container.decodeIfPresent(TimeInterval.self, forKey: .length)
        aspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)
        bitrate = try container.decodeIfPresent(SeedanceBitrate.self, forKey: .bitrate)
        characterOrientation = try container.decodeIfPresent(CharacterOrientation.self, forKey: .characterOrientation)
        cinemaControls = try container.decodeIfPresent(CinemaControls.self, forKey: .cinemaControls) ?? CinemaControls()
        referencesAreFrames = try container.decodeIfPresent(Bool.self, forKey: .referencesAreFrames) ?? false
        usesUnlimited = try container.decodeIfPresent(Bool.self, forKey: .usesUnlimited) ?? false
        operation = try container.decodeIfPresent(PostOperation.self, forKey: .operation)
        variants = try container.decodeIfPresent(Int.self, forKey: .variants) ?? 1
        draftJobID = try container.decodeIfPresent(String.self, forKey: .draftJobID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        // A generation stored at a resolution its mode doesn't render at, such as a Genjutsu Lite Object Swap at
        // 480p from before modes had their own, is the job it is sent as, so the Queue, the Library, the estimate
        // and the cap read the same. An operation keeps the result's resolution.
        self.resolution = operation == nil ? model.fitted(resolution, for: mode) : resolution
    }

    /// The model makes the clip from a start frame and an optional end frame (Seedance's `image-to-video`): the first
    /// and second reference, on a job without a source, on a model with frames.
    public var usesFrames: Bool {
        referencesAreFrames && model.declares(.frames) && source == nil && !mode.isVideoOperation
    }

    /// The inputs `model` takes in `mode`, by `constraints` where they say; a start frame and at most an end frame
    /// for `usesFrames`.
    public func limits(in constraints: ModelConstraintTable = .builtIn) -> ModeLimits {
        var limits = model.limits(for: mode, hasSource: source != nil, constraints: constraints)
        if usesFrames { limits.referenceImages = 1...2 }
        return limits
    }

    /// The REST endpoint the job runs on with an API key (`VideoModel.endpointID`).
    public var endpointID: String {
        model.endpointID(
            for: mode, resolution: resolution, hasMedia: source != nil || !references.isEmpty, usesFrames: usesFrames)
    }

    /// Seconds the result runs: the part Extend adds, else the source selection, else the length asked for.
    public var duration: TimeInterval {
        if mode == .extend { return length ?? 0 }
        return source?.selectedDuration ?? length ?? 0
    }

    /// What the job is called in lists: its `title`, else the source file's name without its extension; for a clip
    /// made without a source, the start of its prompt, else the model.
    public var name: String {
        if let title { return title }
        if let source { return source.fileURL.deletingPathExtension().lastPathComponent }
        let prompt =
            prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !prompt.isEmpty else { return model.title }
        return prompt.count > Self.maxPromptNameLength
            ? String(prompt.prefix(Self.maxPromptNameLength)).trimmingCharacters(in: .whitespaces) + "…" : prompt
    }

    static let maxPromptNameLength = 40

    /// The longest `title`, in characters: what a Queue row or a Library card shows of it.
    public static let maxTitleLength = 80

    /// `text` as a `title`: one line with single spaces, trimmed, cut to `maxTitleLength`; `nil` when nothing is
    /// left. An agent sends it, and it names rows, cards and files: control characters (tabs, newlines, NUL) read as
    /// spaces, and format characters, which would reorder or hide what is shown (bidi overrides such as U+202E,
    /// zero-width spaces), are dropped, except the joiner inside emoji.
    public static func title(from text: String?) -> String? {
        guard let text else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .format where scalar != "\u{200D}": continue
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        let line = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
    }
}
