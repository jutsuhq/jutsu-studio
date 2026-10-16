import Foundation

/// Whether a template starts a video job or an image request. Templates saved before kinds decode as video.
public enum TemplateKind: String, Sendable, Hashable, Codable, CaseIterable {
    case video
    case image
}

/// Saved inputs to start new jobs from: everything a `JobSpec` holds except the source and its range.
/// The references point at copies the app owns, so a template outlives the files it was made from.
/// An image template (`kind == .image`) starts an image request instead: only `imageModelID`,
/// `imageModelTitle`, `imageAspectRatio`, `imageCount`, `prompt` and `references` (the image to edit) apply.
public struct JobTemplate: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var kind: TemplateKind
    public var mode: Mode
    /// The mode's default model (`Mode.defaultModel`) when the model doesn't serve `mode`.
    public var model: VideoModel
    /// Ordered, like `JobSpec.references`.
    public var references: [LocalImage]
    /// Restyle only.
    public var presetID: UUID?
    public var prompt: String
    public var resolution: Resolution
    public var audio: AudioOption
    /// Seedance only, as in `JobSpec`.
    public var bitrate: SeedanceBitrate?
    /// Kling only, as in `JobSpec`.
    public var characterOrientation: CharacterOrientation?
    /// Cinema Studio only, as in `JobSpec`.
    public var cinemaControls: CinemaControls
    /// `references` are a Seedance start frame and an optional end frame (`JobSpec.referencesAreFrames`).
    public var referencesAreFrames: Bool
    /// Image only: the image model's ID, for `ImageModel.id`.
    public var imageModelID: String?
    /// Image only: the model title for display; the ID above is what applies.
    public var imageModelTitle: String?
    /// Image only: the frame, as "W:H".
    public var imageAspectRatio: String?
    /// Image only: how many images one request makes.
    public var imageCount: Int

    public init(
        id: UUID = UUID(), name: String, createdAt: Date = Date(), kind: TemplateKind = .video, mode: Mode,
        model: VideoModel = .genjutsu,
        references: [LocalImage] = [], presetID: UUID? = nil, prompt: String = "", resolution: Resolution,
        audio: AudioOption = .original, bitrate: SeedanceBitrate? = nil,
        characterOrientation: CharacterOrientation? = nil, cinemaControls: CinemaControls = CinemaControls(),
        referencesAreFrames: Bool = false, imageModelID: String? = nil, imageModelTitle: String? = nil,
        imageAspectRatio: String? = nil, imageCount: Int = 1
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.kind = kind
        self.mode = mode
        self.model = model.serves(mode) ? model : mode.defaultModel
        self.references = references
        self.presetID = mode.limits.requiresPreset ? presetID : nil
        self.prompt = prompt
        self.resolution = resolution
        self.audio = audio
        self.bitrate = bitrate
        self.characterOrientation = characterOrientation
        self.cinemaControls = cinemaControls
        self.referencesAreFrames = referencesAreFrames
        self.imageModelID = imageModelID
        self.imageModelTitle = imageModelTitle
        self.imageAspectRatio = imageAspectRatio
        self.imageCount = imageCount
    }

    /// An image template: the model, frame, count, prompt and the image to edit.
    public init(
        id: UUID = UUID(), name: String, createdAt: Date = Date(), imageModelID: String?,
        imageModelTitle: String? = nil,
        imageAspectRatio: String?, imageCount: Int, prompt: String, references: [LocalImage] = []
    ) {
        self.init(
            id: id, name: name, createdAt: createdAt, kind: .image, mode: .motionTransfer, references: references,
            prompt: prompt, resolution: .p720, imageModelID: imageModelID, imageModelTitle: imageModelTitle,
            imageAspectRatio: imageAspectRatio, imageCount: imageCount)
    }

    /// The inputs of `spec`, without its source.
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), spec: JobSpec) {
        self.init(
            id: id, name: name, createdAt: createdAt, mode: spec.mode, model: spec.model, references: spec.references,
            presetID: spec.presetID, prompt: spec.prompt, resolution: spec.resolution, audio: spec.audio,
            bitrate: spec.bitrate, characterOrientation: spec.characterOrientation,
            cinemaControls: spec.cinemaControls, referencesAreFrames: spec.usesFrames)
    }

    /// Templates saved before `model` existed decode as Genjutsu, and before the model parameters without them.
    /// Templates saved before kinds decode as video templates.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(TemplateKind.self, forKey: .kind) ?? .video
        mode = try container.decode(Mode.self, forKey: .mode)
        model = try container.decodeIfPresent(VideoModel.self, forKey: .model) ?? .genjutsu
        references = try container.decode([LocalImage].self, forKey: .references)
        presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
        prompt = try container.decode(String.self, forKey: .prompt)
        resolution = try container.decode(Resolution.self, forKey: .resolution)
        audio = try container.decode(AudioOption.self, forKey: .audio)
        bitrate = try container.decodeIfPresent(SeedanceBitrate.self, forKey: .bitrate)
        characterOrientation = try container.decodeIfPresent(CharacterOrientation.self, forKey: .characterOrientation)
        cinemaControls = try container.decodeIfPresent(CinemaControls.self, forKey: .cinemaControls) ?? CinemaControls()
        referencesAreFrames = try container.decodeIfPresent(Bool.self, forKey: .referencesAreFrames) ?? false
        imageModelID = try container.decodeIfPresent(String.self, forKey: .imageModelID)
        imageModelTitle = try container.decodeIfPresent(String.self, forKey: .imageModelTitle)
        imageAspectRatio = try container.decodeIfPresent(String.self, forKey: .imageAspectRatio)
        imageCount = try container.decodeIfPresent(Int.self, forKey: .imageCount) ?? 1
    }
}

/// Where a template's reference copies go and which leftovers to remove. Decisions only; the caller does the I/O.
public enum TemplateFiles {
    /// The folder of one template's images, inside the templates folder.
    public static func folderName(for templateID: UUID) -> String { templateID.uuidString }

    /// File names for the copies, in order. The position prefix keeps two images with the same name apart
    /// and keeps the order visible in Finder.
    public static func fileNames(for sources: [URL]) -> [String] {
        sources.enumerated().map { index, url in
            let name = url.lastPathComponent
            return "\(index + 1)-\(name.isEmpty ? "image" : name)"
        }
    }

    /// Folders in the templates folder that belong to no saved template, e.g. after a save that failed
    /// once the images were copied.
    public static func orphanedFolders(_ folderNames: [String], keeping templateIDs: Set<UUID>) -> [String] {
        let kept = Set(templateIDs.map(folderName(for:)))
        return folderNames.filter { !kept.contains($0) }.sorted()
    }
}
