import Foundation
import JutsuCore

/// The Create screen's draft jobs: one per range of the source, all with the same inputs. Editing goes through
/// the mutating methods, which keep every range inside the selected model's duration window and apart from the
/// others, and the references inside its limits (`limits`).
public struct CreateForm: Sendable, Hashable, Codable {
    public var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            clamp(to: limits)
            allowsUpscale = false
            if !offersBatch { isBatch = false }
        }
    }
    /// Kept across mode switches; a mode the model doesn't serve runs on Genjutsu (`selectedModel`).
    public var model = VideoModel.genjutsu {
        didSet {
            guard model != oldValue else { return }
            // Within Motion, a model runs one of its own tasks: Kling O3 Edit only edits, Genjutsu doesn't edit.
            if tab == .motionTransfer, !model.serves(mode), let task = Self.motionTasks.first(where: model.serves) {
                mode = task
            }
            clamp(to: limits)
        }
    }
    public internal(set) var source: SourceVideo?
    /// Seconds from the start of the file, sorted and not overlapping; ranges may touch.
    public internal(set) var ranges: [ClosedRange<TimeInterval>] = [0...0]
    /// The range the trim handles move.
    public internal(set) var selectedRangeIndex = 0
    public internal(set) var references: [LocalImage] = []
    /// Kept across mode switches; only restyle sends it.
    public var presetID: UUID?
    public var prompt = ""
    public var resolution: Resolution
    /// What Draft renders at; a setting, so loading a job's inputs keeps it.
    public var draftResolution: Resolution
    public var draftLength = DraftLength.wholeRange
    /// Object swap only: the user accepted upscaling a frame below the minimum.
    public var allowsUpscale = false
    public var audio = AudioOption.original
    /// Kling only: keep the source video's background rather than the reference image's.
    public var keepsVideoBackground = false
    /// Seconds a clip made without a source runs (`isWithoutSource`), or Extend adds; jobs take it inside the
    /// model's limits.
    public var length = CreateForm.defaultLength
    /// The frame of a clip made without a source.
    public var aspectRatio = AspectRatio.auto
    /// Seedance's bitrate, Kling's orientation, Cinema Studio's controls and the variants, as picked; `bitrate(on:)`,
    /// `characterOrientation`, `cinemaControls` and `variants` give each with its default.
    var picks = ModelPicks()
    /// Seedance without a source: the images the clip starts and ends on (`usesFrames`).
    var frames = FramePair()
    /// The library item the inputs were loaded from, recorded on the queued jobs; a new source clears it.
    public internal(set) var parentID: UUID?
    /// Inputs the account already holds, from a generation loaded for editing; a new source clears them.
    public internal(set) var remoteInputs: RemoteInputs?
    /// The batch's styles or character sets (`isBatch`).
    var batch = CreateBatch()
    /// The server's limits of each model, from the app's cache (`ModelConstraintStore`); `nil` keeps the constants.
    /// The app sets it, never an edit. A change brings the ranges and references inside the new limits.
    public var constraints: ModelConstraintTable? {
        didSet {
            guard constraints != oldValue else { return }
            clamp(to: limits)
        }
    }

    public init(
        mode: Mode = AppSettings.defaultMode, resolution: Resolution = AppSettings.defaultResolution,
        draftResolution: Resolution = AppSettings.defaultDraftResolution
    ) {
        self.mode = mode
        self.resolution = resolution
        self.draftResolution = draftResolution
    }

    /// The form a fresh Create screen opens with, from the user's settings.
    public init(settings defaults: UserDefaults) {
        self.init(
            mode: AppSettings.defaultMode(in: defaults), resolution: AppSettings.defaultResolution(in: defaults),
            draftResolution: AppSettings.draftResolution(in: defaults))
    }

    // MARK: Source

    /// Replaces the source; a clip up to the longest a job takes is selected whole, a longer one from the start.
    public mutating func setSource(_ video: SourceVideo?) {
        source = video
        parentID = nil
        remoteInputs = nil
        allowsUpscale = false
        draftLength = .wholeRange
        selectedRangeIndex = 0
        ranges = [0...min(max(0, video?.duration ?? 0), limits.duration.upperBound)]
    }

    /// Cuts the references to `limits` and brings every range's length inside them; a range grows only into
    /// the room before the next range or the end of the clip.
    mutating func clamp(to limits: ModeLimits) {
        references = Array(references.prefix(limits.referenceImages.upperBound))
        guard let total = source?.duration else { return }
        let duration = limits.duration
        for index in ranges.indices {
            let start = ranges[index].lowerBound
            let room = ranges.indices.contains(index + 1) ? ranges[index + 1].lowerBound : total
            let end = min(
                room, max(min(ranges[index].upperBound, start + duration.upperBound), start + duration.lowerBound))
            ranges[index] = start...max(end, start)
        }
    }

    /// The range being edited on the timeline.
    public internal(set) var range: ClosedRange<TimeInterval> {
        get { ranges.indices.contains(selectedRangeIndex) ? ranges[selectedRangeIndex] : 0...0 }
        set {
            guard ranges.indices.contains(selectedRangeIndex) else { return }
            ranges[selectedRangeIndex] = newValue
        }
    }

    public var selectedDuration: TimeInterval { range.upperBound - range.lowerBound }

    /// Moves the start handle; the end stays and the length stays within `limits` where the clip
    /// and the neighboring ranges allow.
    public mutating func setStart(_ time: TimeInterval) {
        guard source != nil, !isSourceRemote else { return }
        let end = range.upperBound
        let window = limits.duration
        let start = max(room.lowerBound, min(max(time, end - window.upperBound), end - window.lowerBound))
        range = min(start, end)...end
    }

    /// Moves the end handle; the start stays.
    public mutating func setEnd(_ time: TimeInterval) {
        guard source != nil, !isSourceRemote else { return }
        let start = range.lowerBound
        let window = limits.duration
        let end = min(room.upperBound, max(min(time, start + window.upperBound), start + window.lowerBound))
        range = start...max(end, start)
    }

    /// Slides the whole selection so it starts at `time`, keeping its length between its neighbors.
    public mutating func moveRange(toStart time: TimeInterval) {
        guard source != nil, !isSourceRemote else { return }
        let length = selectedDuration
        let start = min(max(time, room.lowerBound), max(room.lowerBound, room.upperBound - length))
        range = start...(start + length)
    }

    // MARK: References

    public var referenceLimits: ClosedRange<Int> { limits.referenceImages }
    public var canAddReferences: Bool { references.count < referenceLimits.upperBound }
    /// How many more references the form takes.
    public var referenceRoom: Int { max(referenceLimits.upperBound - references.count, 0) }
    /// "2 / 8".
    public var referenceCountText: String { "\(references.count) / \(referenceLimits.upperBound)" }

    /// Appends images in order, skipping files already added and any beyond the mode's limit.
    /// Returns how many were added.
    @discardableResult
    public mutating func addReferences(_ images: [LocalImage]) -> Int {
        var added = 0
        for image in images {
            if let index = references.firstIndex(where: { $0.fileURL == image.fileURL }) {
                // Already there: keep it, but pinned to the catalog version it now comes with (Make Video).
                if let material = image.material { references[index].material = material }
            } else if canAddReferences {
                references.append(image)
                added += 1
            }
        }
        return added
    }

    public mutating func removeReference(at index: Int) {
        guard references.indices.contains(index) else { return }
        references.remove(at: index)
    }

    /// Moves one image to `newIndex`, clamped to the list.
    public mutating func moveReference(at index: Int, to newIndex: Int) {
        guard references.indices.contains(index) else { return }
        let image = references.remove(at: index)
        references.insert(image, at: min(max(newIndex, 0), references.count))
    }

    // MARK: Prompt

    /// Counted in Unicode scalars, as the API does.
    public var promptLength: Int { prompt.unicodeScalars.count }
    /// "120 / 10 000".
    public var promptCounterText: String { "\(promptLength) / 10 000" }

    // MARK: Object swap upscale

    public var isFrameTooSmall: Bool {
        guard mode == .objectSwap, let size = source?.pixelSize else { return false }
        return size.pixelCount < Validation.objectSwapMinimumPixels
    }

    /// The size the preparer renders a too-small swap frame at.
    public var upscaleTarget: PixelSize? {
        guard isFrameTooSmall, let size = source?.pixelSize else { return nil }
        return Validation.upscaledSize(width: size.width, height: size.height)
    }

    /// Shown next to the upscale toggle while the swap frame is below the minimum.
    public var upscaleNotice: Notice? {
        guard let source, let target = upscaleTarget else { return nil }
        return Notice(
            title: String(
                localized: "\(source.sizeText) is below the 640×640 minimum for object swap.", bundle: .module),
            detail: String(
                localized: """
                    Upscale to \(target.width)×\(target.height) before upload? \
                    Detail won't improve, but the API will accept it.
                    """, bundle: .module))
    }

    /// Short facts over the preview: conversion, upscale, a clip longer than the API takes.
    public var stagePills: [String] {
        guard let source else { return [] }
        var pills: [String] = []
        if source.needsConversion { pills.append(String(localized: "Will convert to MP4 · H.264", bundle: .module)) }
        if allowsUpscale, let target = upscaleTarget {
            let size = "\(target.width)×\(target.height)"
            pills.append(String(localized: "Will upscale to \(size)", bundle: .module))
        }
        if isSourceRemote { pills.append(String(localized: "On Higgsfield · the whole clip is used", bundle: .module)) }
        if source.duration > limits.duration.upperBound, !isSourceRemote {
            let length = CostText.seconds(source.duration)
            let most = CostText.limit(limits.duration.upperBound)
            pills.append(String(localized: "\(length) clip — pick up to \(most) below", bundle: .module))
        }
        return pills
    }

    // MARK: Trim

    /// "00:06.0 – 00:18.5" for the range being edited.
    public var rangeText: String { rangeText(at: selectedRangeIndex) }

    /// "12.5 s selected · billed 13 s"; with several ranges "12.5 s selected · 3 ranges · billed 31 s". The billed
    /// seconds are `connection`'s (`billedSeconds(on:)`).
    public func trimSummary(on connection: ProviderKind?) -> String {
        let selected = CostText.seconds(selectedDuration)
        let billedSeconds = billedSeconds(on: connection)
        guard hasSeveralRanges else {
            return String(localized: "\(selected) selected · billed \(billedSeconds) s", bundle: .module)
        }
        return String(
            localized: "\(selected) selected · \(ranges.count) ranges · billed \(billedSeconds) s", bundle: .module)
    }

    // MARK: Draft

    /// "Draft 480p": the draft resolution, or the nearest the mode renders at (Genjutsu Lite's Object Swap, 720p).
    public var draftTitle: String {
        String(localized: "Draft \(selectedModel.fitted(draftResolution, for: mode).rawValue)", bundle: .module)
    }

    /// Draft is offered on the selected model (`VideoModel.offersDraft`).
    public var offersDraft: Bool { selectedModel.offersDraft }

    /// A batch runs as drafts by default, on a model that has them.
    public var runsAsDraft: Bool { isBatch && offersDraft }

    /// The picker only matters for a draft, when a range is longer than the short one. Extend continues from the
    /// end of its range, so it never cuts the range short.
    public var showsDraftLength: Bool {
        offersDraft && source != nil && !isSourceRemote && mode != .extend
            && ranges.contains { $0.upperBound - $0.lowerBound > DraftLength.shortSeconds }
    }

    /// Seconds a draft renders, over all ranges; a clip made without a source renders whole.
    public var draftDuration: TimeInterval {
        isWithoutSource ? clipLength : ranges.reduce(0) { $0 + draftLength(of: $1) }
    }

    private func draftLength(of range: ClosedRange<TimeInterval>) -> TimeInterval {
        let length = range.upperBound - range.lowerBound
        if isSourceRemote { return length }
        return switch draftLength {
        case .wholeRange: length
        case .firstFiveSeconds: min(length, DraftLength.shortSeconds)
        }
    }

    // MARK: Spec

    /// The jobs to queue, one per range in timeline order; without a source, one clip of `length` when the model
    /// makes one (`isWithoutSource`), else none. A batch queues the edited range once per style or character set
    /// instead (`batchSpecs`).
    /// A draft renders at `draftResolution` and each of its ranges may be cut to its first seconds; on a model
    /// without drafts it is the same as Generate.
    public func makeSpecs(isDraft: Bool) -> [JobSpec] {
        let specs = rangeSpecs(isDraft: isDraft && offersDraft)
        guard isBatch && offersBatch else { return specs }
        return specs.indices.contains(selectedRangeIndex) ? batchSpecs(from: specs[selectedRangeIndex]) : []
    }

    private func rangeSpecs(isDraft: Bool) -> [JobSpec] {
        guard let source else {
            guard isWithoutSource else { return [] }
            let images = usesFrames ? frames.images : references
            return [
                JobSpec(
                    mode: mode, model: selectedModel, source: nil, references: images, prompt: prompt,
                    resolution: jobResolution(isDraft: isDraft), isDraft: isDraft, audio: jobAudio,
                    remoteInputs: reusableInputs(for: images), length: clipLength,
                    aspectRatio: usesFrames ? nil : aspectRatio, bitrate: jobBitrate,
                    referencesAreFrames: usesFrames)
            ]
        }
        return ranges.map { range in
            let length =
                isDraft && mode != .extend ? draftLength(of: range) : range.upperBound - range.lowerBound
            let clip = SourceClip(
                fileURL: source.fileURL, duration: source.duration, pixelSize: source.pixelSize,
                range: range.lowerBound...(range.lowerBound + length),
                allowsUpscale: isFrameTooSmall && allowsUpscale, bookmark: source.bookmark,
                remoteOrigin: source.remoteOrigin)
            return JobSpec(
                mode: mode, model: selectedModel, source: clip, references: references,
                presetID: mode.limits.requiresPreset ? presetID : nil, prompt: prompt,
                resolution: jobResolution(isDraft: isDraft), isDraft: isDraft, audio: jobAudio,
                remoteInputs: reusableInputs,
                keepsVideoBackground: showsVideoBackground && keepsVideoBackground,
                length: mode == .extend ? clipLength : nil, bitrate: jobBitrate,
                characterOrientation: jobCharacterOrientation, cinemaControls: jobCinemaControls)
        }
    }
}

// MARK: Inputs on the account

extension CreateForm {
    /// The source is a file only the account has, so it can't be trimmed: the whole clip is sent.
    public var isSourceRemote: Bool { source.map { !$0.fileURL.isFileURL } ?? false }

    /// The held media IDs while the inputs are still the ones they belong to; references may be removed or
    /// reordered. A local file added since means the job uploads everything instead.
    var reusableInputs: RemoteInputs? { reusableInputs(for: references) }

    /// The held media IDs for these references, or `nil` when any of them isn't one the IDs belong to.
    func reusableInputs(for references: [LocalImage]) -> RemoteInputs? {
        guard let remoteInputs, source?.fileURL == remoteInputs.video?.url else { return nil }
        var images: [RemoteAsset] = []
        for reference in references {
            guard let image = remoteInputs.images.first(where: { $0.url == reference.fileURL }) else { return nil }
            images.append(image)
        }
        return RemoteInputs(video: remoteInputs.video, images: images)
    }
}

// MARK: Loading

extension CreateForm {
    /// Opens a queued or finished job's inputs for editing ("Edit inputs", "Render final").
    /// `source` is the clip probed again; `nil` when it can't be read any more, so the form has no source.
    /// `parentID` is the library item the inputs come from, `nil` for a job that isn't in the library.
    public mutating func load(_ spec: JobSpec, source video: SourceVideo?, parentID: UUID? = nil) {
        mode = spec.mode
        model = spec.model
        setSource(video)
        // The clip probed again is the same file, so it still came from the same link.
        if source?.remoteOrigin == nil { source?.remoteOrigin = spec.source?.remoteOrigin }
        if let video, !video.fileURL.isFileURL {
            range = 0...max(0, video.duration)
            remoteInputs = spec.remoteInputs
        } else if let video, let clip = spec.source {
            // Extend continues from the end of its selection, so one that reached the end of the clip still does
            // when the file probes a little longer than recorded, and keeps inside the window from there.
            let isExtendToEnd = spec.mode == .extend && clip.range.upperBound >= clip.duration
            let end = isExtendToEnd ? video.duration : min(clip.range.upperBound, video.duration)
            let start = min(max(0, clip.range.lowerBound), end)
            range = (isExtendToEnd ? max(start, end - limits.duration.upperBound) : start)...end
        } else if spec.source == nil {
            length = spec.length ?? Self.defaultLength
            aspectRatio = spec.aspectRatio ?? .auto
            remoteInputs = spec.remoteInputs
        }
        if spec.mode == .extend { length = spec.length ?? Self.defaultLength }
        if spec.usesFrames {
            references = []
            frames = FramePair(spec.references)
        } else {
            references = Array(spec.references.prefix(limits.referenceImages.upperBound))
            frames = FramePair()
        }
        presetID = spec.presetID
        prompt = spec.prompt
        resolution = spec.resolution
        allowsUpscale = spec.source?.allowsUpscale ?? false
        audio = spec.audio
        keepsVideoBackground = spec.keepsVideoBackground
        if let bitrate = spec.bitrate { picks.bitrate = bitrate }
        if let orientation = spec.characterOrientation { picks.orientation = orientation }
        if spec.model.declares(.cinemaControls) { cinemaControls = spec.cinemaControls }
        picks.variants = spec.variants > 1 ? spec.variants : nil
        self.parentID = parentID
        isBatch = false
    }
}

// MARK: Kling quality

extension CreateForm {
    /// Kling has Standard and Pro instead of resolutions (`KlingQuality`).
    public var showsKlingQuality: Bool { selectedModel.declares(.quality) }

    /// Kling's "Keep the video's background".
    public var showsVideoBackground: Bool { selectedModel.declares(.videoBackground) }

    /// Kept in `resolution`, so switching to another model and back keeps it: a resolution below 1080p is
    /// Standard.
    public var klingQuality: KlingQuality {
        get { KlingQuality(resolution) }
        set { resolution = newValue.resolution }
    }

    /// The resolution the jobs of Draft (`isDraft`) or Generate are made at; Kling's is its quality's, and another
    /// model's the nearest it renders at in the mode (`VideoModel.fitted(_:for:)`).
    func jobResolution(isDraft: Bool) -> Resolution {
        if showsKlingQuality { return klingQuality.resolution }
        return selectedModel.fitted(isDraft ? draftResolution : resolution, for: mode)
    }
}

// MARK: Resolutions

extension CreateForm {
    /// The resolution picker's entries: the ones the selected model renders at in the mode
    /// (`VideoModel.resolutions(for:)`), such as Wan 2.7's 720p and 1080p, or Genjutsu Lite's in Object Swap.
    public var resolutionOptions: [Resolution] { selectedModel.resolutions(for: mode) }

    /// The picker's selection: the resolution the jobs are made at. Set, it becomes the form's `resolution`, so a
    /// model with fewer resolutions doesn't change what the others get back when they are picked again.
    public var pickedResolution: Resolution {
        get { selectedModel.fitted(resolution, for: mode) }
        set { resolution = newValue }
    }
}

// MARK: Without a source

extension CreateForm {
    /// Seedance's own default length.
    public static let defaultLength: TimeInterval = 5

    /// No video is picked and the selected model makes a clip from the prompt and images alone; Edit and Extend
    /// always need one.
    public var isWithoutSource: Bool {
        source == nil && selectedModel.makesClipsWithoutSource && !mode.isVideoOperation
    }

    /// `length` inside the model's limits, as the job takes it: the clip made without a source, or what Extend adds.
    public var clipLength: TimeInterval {
        min(max(length, limits.duration.lowerBound), limits.duration.upperBound)
    }

    /// A clip made without a source needs the prompt unless an image shows what to make; Edit, Extend and a model
    /// that needs a prompt (`requiresPrompt`, Kling O3) always do, except Kling 4.0 from frames (`Validation`).
    public var promptTitle: String {
        (isWithoutSource && references.isEmpty && !usesFrames) || mode.isVideoOperation
            || (selectedModel.descriptor.requiresPrompt && !usesFrames)
            ? String(localized: "Prompt", bundle: .module) : String(localized: "Prompt · optional", bundle: .module)
    }

    /// The model makes the sound: a clip made without a source, or the part Extend adds, which no source sound
    /// belongs to. Otherwise the result gets the source's.
    public var generatesAudio: Bool { isWithoutSource || mode == .extend }

    public var promptHint: String {
        isWithoutSource
            ? String(
                localized: "Describe the clip, e.g. “A fox runs through fresh snow at dawn, slow motion”",
                bundle: .module) : mode.promptHint
    }
}

// MARK: Edit and Extend

extension CreateForm {
    /// Motion's tasks: a model that changes or continues a clip (Seedance, Kling O3 Edit) does that from the Motion
    /// tab, picked under the model, rather than from tabs of their own.
    static let motionTasks: [Mode] = [.motionTransfer, .edit, .extend]

    /// The mode picker's tabs.
    public var modeChoices: [Mode] { [.motionTransfer, .restyle, .objectSwap] }

    /// The tab the mode belongs to: Edit and Extend are Motion's. Picking Motion runs the model's first task.
    public var tab: Mode {
        get { mode.isVideoOperation ? .motionTransfer : mode }
        set {
            guard newValue != tab else { return }
            mode =
                newValue == .motionTransfer
                ? Self.motionTasks.first(where: model.serves) ?? .motionTransfer : newValue
        }
    }

    /// What the picked model can do in the Motion tab on this connection; the task picker shows when there is more
    /// than one.
    public func taskChoices(in context: CreateContext) -> [Mode] {
        guard tab == .motionTransfer else { return [] }
        return Self.motionTasks.filter { task in
            selectedModel.serves(task) && (task == mode || context.unavailableReason(for: task) == nil)
        }
    }

    /// Picks one of `taskChoices`, keeping the model the picker shows.
    public mutating func pickTask(_ task: Mode) {
        model = selectedModel
        mode = task
    }

    /// Extend's length section takes the place of the trim's length: "Add 4–30 s".
    public var showsAddedLength: Bool { mode == .extend }

    /// "Add 4–30 s".
    public var addedLengthTitle: String {
        let window = limits.duration
        return String(
            localized: "Add \(Int(window.lowerBound))–\(Int(window.upperBound)) s", bundle: .module)
    }

    /// A batch compares styles or characters; Edit and Extend have neither.
    public var offersBatch: Bool { !mode.isVideoOperation }
}

/// A warning with one line of detail.
public struct Notice: Sendable, Hashable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}
