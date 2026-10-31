import Foundation
import JutsuCore

/// A video an agent asks for, with its files already in the app: what the app makes of a `quote` or `create_video`.
/// It becomes a job through a `CreateForm` of its own, never the Create screen's draft, so it is built and checked
/// exactly as the person's own job would be (`spec(from:in:)`), and refused where the form would quietly fit it: a
/// length outside the model's window, a reference too many, a resolution or draft the model doesn't have.
public struct AgentVideoOrder: Sendable, Hashable {
    /// The source clip, probed (`SourceVideo`); for a quote, a stand-in as long as the range's end.
    public struct Source: Sendable, Hashable {
        public var video: SourceVideo
        public var start: TimeInterval?
        public var end: TimeInterval?

        public init(video: SourceVideo, start: TimeInterval? = nil, end: TimeInterval? = nil) {
            self.video = video
            self.start = start
            self.end = end
        }
    }

    /// "motion_transfer", "restyle", "object_swap", "edit", "extend".
    public var mode: String
    public var model: String?
    public var prompt: String
    public var source: Source?
    public var images: [LocalImage]
    public var style: UUID?
    public var resolution: String?
    public var isDraft: Bool
    public var length: TimeInterval?
    public var aspectRatio: String?
    public var audio: String?
    public var variants: Int?
    /// The job's name in lists, as the agent sent it; the job keeps it trimmed and cut (`JobSpec.title(from:)`).
    public var title: String?

    public init(
        mode: String, model: String? = nil, prompt: String = "", source: Source? = nil, images: [LocalImage] = [],
        style: UUID? = nil, resolution: String? = nil, isDraft: Bool = false, length: TimeInterval? = nil,
        aspectRatio: String? = nil, audio: String? = nil, variants: Int? = nil, title: String? = nil
    ) {
        self.mode = mode
        self.model = model
        self.prompt = prompt
        self.source = source
        self.images = images
        self.style = style
        self.resolution = resolution
        self.isDraft = isDraft
        self.length = length
        self.aspectRatio = aspectRatio
        self.audio = audio
        self.variants = variants
        self.title = title
    }

    /// A quote's stand-in for a source of `end` seconds: only its length and frame matter to a price.
    public static func quoteSource(start: TimeInterval?, end: TimeInterval) -> Source {
        Source(
            video: SourceVideo(
                fileURL: URL(filePath: "/quote/source.mp4"), duration: end,
                pixelSize: PixelSize(width: 1280, height: 720), codec: "avc1", fileSize: 0),
            start: start, end: end)
    }

    /// A quote's stand-ins for `count` reference images.
    public static func quoteImages(_ count: Int) -> [LocalImage] {
        (0..<max(0, count)).map { LocalImage(fileURL: URL(filePath: "/quote/image-\($0).png")) }
    }

    static let modes: [String: Mode] = [
        "motion_transfer": .motionTransfer, "restyle": .restyle, "object_swap": .objectSwap, "edit": .edit,
        "extend": .extend,
    ]

    /// The mode an agent names; `nil` for a name that isn't one.
    public static func mode(named name: String) -> Mode? { modes[name] }

    /// The frame `spec`'s result gets, as `quote` says it: `source` when the job has one (its result keeps the
    /// source's orientation, Seedance asking for the source's nearest ratio), else the ratio the job asks for.
    public static func frame(of spec: JobSpec) -> String? {
        guard spec.source != nil else { return spec.aspectRatio?.rawValue }
        return choosesOwnFrame(spec.model) ? "model" : "source"
    }

    /// What `quote` says about the frame of a model that picks it itself; nil for the others.
    public static func frameNote(of spec: JobSpec) -> String? {
        guard spec.source != nil, choosesOwnFrame(spec.model) else { return nil }
        return "\(spec.model.title) takes no aspect ratio and picks the result's frame itself: it usually follows the "
            + "source, but a 3:4 result from a 9:16 source has been seen. jobs gives the result's width and height "
            + "once it is done, with frameNote when they aren't the source's shape; check them before scaling it."
    }

    /// Models with a source that Higgsfield sends no aspect ratio to (their catalog lists none) and that were seen to
    /// answer in another frame than the source's: Genjutsu Lite (issue #38).
    static func choosesOwnFrame(_ model: VideoModel) -> Bool {
        model.rawValue == "genjutsuLite"
    }

    /// The agent's name for `mode`.
    public static func name(of mode: Mode) -> String {
        modes.first { $0.value == mode }?.key ?? mode.rawValue
    }

    static let audioOptions: [String: AudioOption] = [
        "original": .original, "mute": .mute, "fade_out": .fadeOut, "generated": .generated,
    ]

    /// Why the order can't be a job, in English for the agent.
    public struct Refusal: Error, Sendable, Hashable {
        public var message: String

        init(_ message: String) {
            self.message = message
        }
    }

    /// The one job this order makes, or why not.
    /// - Parameters:
    ///   - base: a fresh form with the person's defaults (`CreateForm(settings:)`), never the Create draft.
    ///   - context: the connection, its capabilities and prices, as Create sees them.
    ///   - constraints: the server's model limits the app holds; `nil` keeps the built-in ones.
    public func spec(
        from base: CreateForm, in context: CreateContext, constraints: ModelConstraintTable? = nil
    ) -> Result<JobSpec, Refusal> {
        do throws(Refusal) {
            return .success(try build(base, in: context, constraints: constraints))
        } catch {
            return .failure(error)
        }
    }

    private func build(
        _ base: CreateForm, in context: CreateContext, constraints: ModelConstraintTable?
    ) throws(Refusal) -> JobSpec {
        guard let mode = Self.modes[self.mode] else {
            throw Refusal("mode is one of \(Self.modes.keys.sorted().joined(separator: ", ")).")
        }
        guard context.connection.isConnected else {
            throw Refusal("Jutsu Studio isn't connected to Higgsfield; the person connects it in Settings.")
        }
        let model = try pickModel(for: mode)
        if let offered = context.capabilities?.models, !offered.contains(model) {
            throw Refusal("\(model.title) isn't available on this connection.")
        }
        if let reason = context.unavailableReason(for: mode) { throw Refusal(reason) }
        var form = base
        form.constraints = constraints
        form.isBatch = false
        form.mode = mode
        form.model = model
        guard form.mode == mode, form.selectedModel == model else {
            throw Refusal("\(model.title) can't run \(self.mode).")
        }
        if isDraft, !model.offersDraft { throw Refusal("\(model.title) has no drafts; leave draft out.") }
        if let resolution = try pickResolution(for: model, in: mode) {
            if isDraft { form.draftResolution = resolution } else { form.resolution = resolution }
        }
        try place(source, in: &form)
        // Set as given, never cut to the limits: Validation names what is over.
        form.references = images
        form.prompt = prompt
        form.presetID = style
        try setLength(in: &form)
        try setAspectRatio(in: &form)
        try setAudio(in: &form)
        try setVariants(in: &form, context: context)
        let specs = form.makeSpecs(isDraft: isDraft, in: context)
        guard specs.count == 1, var spec = specs.first else {
            throw Refusal(
                form.source == nil
                    ? "\(model.title) needs a source clip in \(self.mode)." : "The request makes no job.")
        }
        if let issue = Validation.check(spec, constraints: constraints ?? .builtIn).first {
            throw Refusal(Self.text(for: issue, spec: spec, constraints: constraints ?? .builtIn))
        }
        spec.title = JobSpec.title(from: title)
        return spec
    }

    private func setLength(in form: inout CreateForm) throws(Refusal) {
        guard let length else { return }
        form.length = length
        let window = form.limits.duration
        guard form.isWithoutSource || form.mode == .extend else {
            throw Refusal("length is only for a clip without a source, or extend; the source range sets it.")
        }
        if !window.contains(length) {
            throw Refusal(
                "length is \(Self.seconds(window.lowerBound)) to \(Self.seconds(window.upperBound)) seconds on "
                    + "\(form.selectedModel.title).")
        }
    }

    private func pickModel(for mode: Mode) throws(Refusal) -> VideoModel {
        guard let id = model else { return mode.defaultModel }
        guard let model = VideoModel(rawValue: id) else {
            throw Refusal("There's no model \(id); capabilities with models true lists them.")
        }
        guard model.serves(mode) else {
            let modes = model.modes.map(Self.name(of:)).joined(separator: ", ")
            throw Refusal("\(model.title) doesn't do \(self.mode); it does \(modes).")
        }
        return model
    }

    /// The resolution asked for, if the model renders at it in `mode` (`VideoModel.resolutions(for:)`).
    private func pickResolution(for model: VideoModel, in mode: Mode) throws(Refusal) -> Resolution? {
        guard let name = resolution else { return nil }
        let offered = model.resolutions(for: mode)
        guard let resolution = Resolution(rawValue: name), offered.contains(resolution) else {
            let names = offered.map(\.rawValue).joined(separator: ", ")
            let place = offered == model.resolutions ? "" : " in \(self.mode)"
            throw Refusal("\(model.title) renders at \(names)\(place), not \(name).")
        }
        return resolution
    }

    /// The source and its one range, as given: a range past the clip or outside the model's window is refused by
    /// Validation rather than moved.
    private func place(_ source: Source?, in form: inout CreateForm) throws(Refusal) {
        guard let source else { return }
        let video = source.video
        guard video.duration.isFinite, video.duration > 0 else { throw Refusal("The source clip has no length.") }
        form.setSource(video)
        let start = source.start ?? 0
        let end = source.end ?? min(video.duration, start + form.limits.duration.upperBound)
        guard start < end else { throw Refusal("source.end comes after source.start.") }
        guard end <= video.duration + 0.05 else {
            throw Refusal("source.end is past the clip, which runs \(Self.seconds(video.duration)) seconds.")
        }
        form.ranges = [start...min(end, video.duration)]
        form.selectedRangeIndex = 0
        // The API takes no smaller frame for a swap; the agent asked for one, so the frame is upscaled as the person
        // would allow it.
        if form.isFrameTooSmall { form.allowsUpscale = true }
    }

    private func setAspectRatio(in form: inout CreateForm) throws(Refusal) {
        guard let name = aspectRatio else { return }
        guard let ratio = AspectRatio(rawValue: name) else {
            throw Refusal("aspect_ratio is one of \(AspectRatio.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard form.isWithoutSource else { throw Refusal("aspect_ratio is only for a clip without a source.") }
        form.aspectRatio = ratio
    }

    private func setAudio(in form: inout CreateForm) throws(Refusal) {
        guard let name = audio else { return }
        guard let option = Self.audioOptions[name] else {
            throw Refusal("audio is one of \(Self.audioOptions.keys.sorted().joined(separator: ", ")).")
        }
        if option == .generated, !form.offersGeneratedAudio {
            throw Refusal("\(form.selectedModel.title) can't make the sound here; leave audio out or keep original.")
        }
        form.audio = option
    }

    private func setVariants(in form: inout CreateForm, context: CreateContext) throws(Refusal) {
        guard let variants, variants != 1 else { return }
        guard CreateForm.variantChoices.contains(variants) else {
            throw Refusal("variants is 1 to \(CreateForm.variantChoices.upperBound).")
        }
        form.variants = variants
        guard form.variants(in: context) == variants else {
            let reason = form.variantsUnavailableReason(in: context)
            let most = context.capabilities?.maxVariants ?? 1
            throw Refusal(reason.map { "\($0)." } ?? "This connection makes at most \(most) videos per job.")
        }
    }

    /// The issue as the agent reads it, with the model's limits.
    static func text(for issue: ValidationIssue, spec: JobSpec, constraints: ModelConstraintTable) -> String {
        let limits = spec.limits(in: constraints)
        let model = spec.model.title
        switch issue {
        case .selectionOutsideSource: return "The source range is outside the clip."
        case .sourceRequired: return "\(model) needs a source clip for \(name(of: spec.mode))."
        case .promptRequired where spec.mode.isVideoOperation || spec.model.descriptor.requiresPrompt:
            return "\(model) needs a prompt here."
        case .promptRequired: return "A clip without a source needs a prompt or an image."
        case .invalidFrameSize: return "The source clip's frame size can't be read."
        case .durationTooShort(let duration):
            return
                "\(Self.seconds(duration)) seconds is too short: \(model) takes \(Self.seconds(limits.duration.lowerBound)) "
                + "to \(Self.seconds(limits.duration.upperBound)) seconds."
        case .durationTooLong(let duration):
            return
                "\(Self.seconds(duration)) seconds is too long: \(model) takes \(Self.seconds(limits.duration.lowerBound)) "
                + "to \(Self.seconds(limits.duration.upperBound)) seconds."
        case .tooFewReferences(let minimum): return "\(model) needs at least \(minimum) image(s) here."
        case .tooManyReferences(let maximum): return "\(model) takes at most \(maximum) image(s) here."
        case .presetRequired: return "restyle needs style, a style ID."
        case .frameTooSmall: return "The source frame is below 640×640 for object_swap."
        case .promptTooLong: return "The prompt is over 10 000 characters."
        }
    }

    /// "4", "12.5": seconds as an agent reads them, never in the person's locale.
    static func seconds(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "?" }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
