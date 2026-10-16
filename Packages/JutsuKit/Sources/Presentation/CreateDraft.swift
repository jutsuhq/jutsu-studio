import Foundation
import JutsuCore

extension CreateForm {
    /// Something the user put into the form: a source, images, a prompt, a style or batch entries.
    /// Mode, model and output settings alone aren't, so a form with only those is restored as a fresh one.
    public var hasInputs: Bool {
        source != nil || !references.isEmpty || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || presetID != nil || !characterSets.isEmpty || !batchPresetIDs.isEmpty || !frames.isEmpty
    }

    /// Whether this form, replacing `previous`, loses an input `previous` had: its source or the ranges cut from
    /// it, its images or frames, prompt, style or batch entries. Filling an input that was empty loses nothing.
    public func dropsInputs(of previous: CreateForm) -> Bool {
        let hadPrompt = !previous.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (previous.source != nil && (source != previous.source || ranges != previous.ranges))
            || (!previous.references.isEmpty && references != previous.references)
            || (hadPrompt && prompt != previous.prompt)
            || (previous.presetID != nil && presetID != previous.presetID)
            || (!previous.characterSets.isEmpty && characterSets != previous.characterSets)
            || (!previous.batchPresetIDs.isEmpty && batchPresetIDs != previous.batchPresetIDs)
            || (previous.frames.start != nil && frames.start != previous.frames.start)
            || (previous.frames.end != nil && frames.end != previous.frames.end)
    }

    /// The local files the form points at: its source, references, character sets and frames. Clear Cache keeps them,
    /// as many live in the folders it empties (pasted images, downloaded links, picked uploads).
    public var localFiles: Set<URL> {
        let images = references + characterSets.joined() + frames.images
        return Set(([source?.fileURL].compactMap(\.self) + images.map(\.fileURL)).filter(\.isFileURL))
    }

    /// The form with its local files reopened by `reopen`, which returns where a file is now (with a refreshed
    /// bookmark) or `nil` when it can't be read any more. Unreadable files are dropped; a dropped source takes its
    /// ranges with it. Files on the account (not file URLs) are kept as they are.
    public func reopeningFiles(_ reopen: (LocalImage) -> LocalImage?) -> CreateForm {
        func reopened(_ file: LocalImage) -> LocalImage? { file.fileURL.isFileURL ? reopen(file) : file }
        var form = self
        if let source {
            if let file = reopened(LocalImage(fileURL: source.fileURL, bookmark: source.bookmark)) {
                form.source?.fileURL = file.fileURL
                form.source?.bookmark = file.bookmark
            } else {
                form.setSource(nil)
            }
        }
        form.references = references.compactMap(reopened)
        form.batch = batch.reopeningSets(reopened)
        form.frames.start = frames.start.flatMap(reopened)
        form.frames.end = frames.end.flatMap(reopened)
        return form
    }
}

/// A Create draft replaced by Edit inputs, a template or a prompt from history, kept so the toast can undo it.
public struct DraftReplacement: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// The form as it was before the replacement.
    public let previous: CreateForm

    /// `nil` when nothing worth undoing was lost: `replaced` drops none of `previous`'s inputs, or `previous` is
    /// still exactly what the last replacement left (`untouched`), so the user hadn't edited it.
    public init?(previous: CreateForm, replaced: CreateForm, untouched: CreateForm?, id: UUID = UUID()) {
        guard previous != untouched, replaced.dropsInputs(of: previous) else { return nil }
        self.id = id
        self.previous = previous
    }

    /// "Draft replaced".
    public static let title = String(localized: "Draft replaced", bundle: .module)
    public static let undo = String(localized: "Undo", bundle: .module)
    /// How long the toast stays up, in seconds; longer than `QueuedNotice`, as it is the only way back.
    public static let duration: TimeInterval = 10
}

/// The Create draft saved between launches, as one JSON file: the video form and the image form beside it,
/// with the side Create opens on.
public struct CreateDraftStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Bumped when the saved drafts change shape; a file of another version is ignored rather than half-read.
    static let version = 2

    /// Both drafts together; `kind` is the side Create opens on.
    public struct Drafts: Sendable, Hashable {
        public var video: CreateForm?
        public var image: ImageDraft?
        public var kind: TemplateKind

        public init(video: CreateForm? = nil, image: ImageDraft? = nil, kind: TemplateKind = .video) {
            self.video = video
            self.image = image
            self.kind = kind
        }
    }

    private struct SavedDrafts: Codable {
        var version: Int
        var video: CreateForm?
        var image: ImageDraft?
        var kind: TemplateKind?
    }

    /// The v1 file: the video form alone, before the image side existed.
    private struct SavedDraftV1: Codable {
        var version: Int
        var form: CreateForm
    }

    /// Where the v1 file is copied before the first v2 save overwrites it, so the old draft survives a downgrade.
    var backupURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("v1.json")
    }

    /// The saved drafts; `nil` when there is none, it can't be read or another version wrote it. A v1 file reads
    /// as the video draft on the video side.
    public func load() -> Drafts? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let saved = try? JSONDecoder().decode(SavedDrafts.self, from: data), saved.version == Self.version {
            return Drafts(video: saved.video, image: saved.image, kind: saved.kind ?? .video)
        }
        if let saved = try? JSONDecoder().decode(SavedDraftV1.self, from: data), saved.version == 1 {
            return Drafts(video: saved.form, kind: .video)
        }
        return nil
    }

    public func save(_ drafts: Drafts) throws {
        backUpV1()
        let saved = SavedDrafts(version: Self.version, video: drafts.video, image: drafts.image, kind: drafts.kind)
        let data = try JSONEncoder().encode(saved)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Copies a v1 file aside before it is overwritten, so it can still be read back. A v2 file, a missing file
    /// or an unreadable one needs no backup.
    private func backUpV1() {
        guard let data = try? Data(contentsOf: fileURL),
            let saved = try? JSONDecoder().decode(SavedDraftV1.self, from: data), saved.version == 1
        else { return }
        try? FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    /// The saved drafts with their files reopened (`CreateForm.reopeningFiles`, `ImageDraft.reopeningFiles`);
    /// a side with no inputs left comes back `nil`, so Create opens it fresh. The kind is kept either way.
    public func restore(reopen: (LocalImage) -> LocalImage?) -> Drafts {
        guard let drafts = load() else { return Drafts() }
        let video = drafts.video.map { $0.reopeningFiles(reopen) }.flatMap { $0.hasInputs ? $0 : nil }
        let image = drafts.image.map { $0.reopeningFiles(reopen) }.flatMap { $0.hasInputs ? $0 : nil }
        return Drafts(video: video, image: image, kind: drafts.kind)
    }
}
