import Foundation
import JutsuCore
import MediaKit
import Observation
import Presentation
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Create")

/// The sidebar selection plus hand-offs between screens, e.g. Queue asking Create to open a job's inputs.
@MainActor
@Observable
final class NavigationModel {
    var selection: Screen? = .create
    /// Inputs Create should load; Create sets it back to `nil` once it has taken them.
    var pendingEdit: JobSpec?
    /// The library item `pendingEdit` comes from; the jobs queued from it record it as their parent.
    var pendingEditParent: UUID?
    /// The job Library should select; Library sets it back to `nil` once shown.
    var libraryFocus: UUID?
    /// The Queue row selected for the Queue menu's Cancel Job and Retry, kept across screens.
    var queueSelection: UUID?
    /// Files from Open With or the Dock icon; Create takes them once it is on screen.
    var pendingOpens = PendingOpens()
    /// Library images to make a video from; Create's video side asks for their role and takes them.
    var pendingMakeVideo: MakeVideoRequest?
    /// An Enhance sheet on this Mac an agent asked the person to see (`show` with a sheet); `nil` once closed.
    var onDeviceSheet: OnDeviceTarget?
    /// The Create form, kept here so it survives switching screens, and saved so it survives a relaunch.
    /// Replace it as a whole through `replaceDraft`, which offers the edits it loses back.
    var createDraft: CreateForm {
        didSet {
            guard createDraft != oldValue else { return }
            scheduleDraftSave()
        }
    }
    /// The Image side of Create: a snapshot of Generate…'s form (`ReferenceGenerator.snapshot`), kept so
    /// switching Video ⇄ Image never loses either side, and saved so it survives a relaunch. Create keeps it
    /// in step with the generator while it is on screen; the menu bar syncs it when it applies a template.
    var imageDraft: ImageDraft {
        didSet {
            guard imageDraft != oldValue else { return }
            scheduleDraftSave()
        }
    }
    /// The side Create opens on. Switching saves both drafts, so nothing is lost either way.
    var createKind: TemplateKind {
        didSet {
            guard createKind != oldValue else { return }
            scheduleDraftSave()
        }
    }
    /// What applying a template from the menu bar reports; Create shows it. `nil` once it is gone.
    var templateNotice: UserMessage?
    /// What the last submit queued, shown for a moment over every screen; `nil` once it is gone.
    var queuedNotice: QueuedNotice? {
        didSet {
            if queuedNotice != nil { draftReplacement = nil }
        }
    }
    /// The draft the last replacement lost, offered back in the toast; `nil` once it is gone.
    var draftReplacement: DraftReplacement?
    /// The server's model constraints the draft's limits are read through (`useModelConstraints`).
    private(set) var modelConstraints = ModelConstraintTable.builtIn

    /// The draft as the last replacement left it: replacing it again while unchanged loses no edits.
    @ObservationIgnored private var untouchedDraft: CreateForm?
    @ObservationIgnored private let draftStore: CreateDraftStore?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?

    /// - Parameter draftStore: where the drafts are restored from and saved to; `nil` keeps them in memory only.
    init(draftStore: CreateDraftStore? = nil, defaults: UserDefaults = .standard) {
        self.draftStore = draftStore
        let restored = draftStore?.restore { $0.reopened() } ?? CreateDraftStore.Drafts()
        createDraft = restored.video ?? CreateForm(settings: defaults)
        imageDraft = restored.image ?? ImageDraft()
        createKind = restored.kind
        // The table a saved draft carries may be another account's or out of date; the app sets the current one.
        createDraft.constraints = nil
    }

    /// Reads the draft's limits through `table` from now on, the constants for `builtIn`.
    func useModelConstraints(_ table: ModelConstraintTable) {
        modelConstraints = table
        createDraft.constraints = table == .builtIn ? nil : table
    }

    /// Changes the draft with `change`, e.g. loading a job's inputs or applying a template. When that loses inputs
    /// the user had edited, the toast offers them back with Undo.
    @discardableResult
    func replaceDraft<Result>(_ change: (inout CreateForm) -> Result) -> Result {
        let previous = createDraft
        let result = change(&createDraft)
        if let replacement = DraftReplacement(previous: previous, replaced: createDraft, untouched: untouchedDraft) {
            queuedNotice = nil
            draftReplacement = replacement
        }
        untouchedDraft = createDraft
        return result
    }

    /// The local files of both drafts, and of the one the Undo toast still offers back, which Clear Cache keeps.
    var draftFiles: Set<URL> {
        createDraft.localFiles.union(imageDraft.localFiles).union(draftReplacement?.previous.localFiles ?? [])
    }

    func undo(_ replacement: DraftReplacement) {
        createDraft = replacement.previous
        createDraft.constraints = modelConstraints == .builtIn ? nil : modelConstraints
        untouchedDraft = nil
        if draftReplacement?.id == replacement.id { draftReplacement = nil }
    }

    /// Saves the draft a second after the last change, so typing doesn't write on every key.
    private func scheduleDraftSave() {
        guard draftStore != nil else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    /// Writes a pending change now; the app calls it on quit.
    func saveDraft() {
        guard let draftStore, let task = draftSaveTask else { return }
        task.cancel()
        draftSaveTask = nil
        do {
            try draftStore.save(CreateDraftStore.Drafts(video: createDraft, image: imageDraft, kind: createKind))
        } catch {
            logger.error("Can't save the Create draft: \(String(describing: error), privacy: .private)")
        }
    }

    func edit(_ spec: JobSpec, parentID: UUID? = nil) {
        pendingEdit = spec
        pendingEditParent = parentID
        selection = .create
    }

    func open(_ urls: [URL]) {
        pendingOpens.add(OpenRequest(urls, conformsTo: Self.conforms))
        selection = .create
    }

    /// Opens Create's video side with `images`, which asks for their role where more than one fits the model.
    func makeVideo(from images: [LocalImage]) {
        guard !images.isEmpty else { return }
        pendingMakeVideo = MakeVideoRequest(images: images)
        createKind = .video
        selection = .create
    }

    private static func conforms(_ url: URL, to identifier: String) -> Bool {
        guard let type = UTType(identifier), let fileType = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return fileType.conforms(to: type)
    }

    func showInLibrary(_ jobID: UUID) {
        libraryFocus = jobID
        selection = .library
    }

    /// Shows the Queue with the job's row selected.
    func showInQueue(_ jobID: UUID) {
        queueSelection = jobID
        selection = .queue
    }
}
