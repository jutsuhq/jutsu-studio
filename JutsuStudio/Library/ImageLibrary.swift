import Foundation
import JobEngine
import JutsuCore
import Observation
import Persistence
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Images")

/// Library › Images: every image Generate… made, saved in the output folder's `Images` folder as soon as it is
/// ready, like a video result, because the provider's links expire. What made each one is kept in the material catalog.
@MainActor
@Observable
final class ImageLibrary {
    /// Newest first.
    private(set) var images: [SavedImage] = []
    /// Images being downloaded into the library.
    private(set) var saving: Set<UUID> = []
    /// Images whose file can't be opened right now: deleted in Finder, or on a drive that isn't connected. They stay
    /// listed, and stay in the index, until the user removes them.
    private(set) var unavailable: Set<UUID> = []

    @ObservationIgnored private let catalog: SwiftDataStore
    @ObservationIgnored private let pending: PendingImageSaves
    private(set) var failure: UserMessage?
    @ObservationIgnored private let layout: FileLayout
    @ObservationIgnored private let outputFolder: OutputFolder
    /// The downloads `save(_:then:)` started, which a quit waits for (`finishSaving`).
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]
    /// Account images being downloaded into the library, by generation ID: a second "Download to Library"
    /// of one generation joins the first instead of saving it twice.
    @ObservationIgnored private var imports: [String: Task<SavedImage?, Never>] = [:]
    /// The runs on this Mac, which `trash` stops for its images first; set once at launch.
    @ObservationIgnored weak var onDeviceRuns: OnDeviceRuns?

    init(layout: FileLayout, outputFolder: OutputFolder, catalog: SwiftDataStore) {
        self.layout = layout
        self.outputFolder = outputFolder
        self.catalog = catalog
        pending = PendingImageSaves(folder: layout.root)
    }

    /// `Images` in the current output folder; earlier folders keep the images saved there.
    var folder: URL { outputFolder.url(of: .images) }

    /// Refreshes the download controller's view of catalog images and unavailable files.
    func load() async {
        do {
            images = try await catalog.materials().filter { !$0.isHidden }.compactMap(MaterialLibrary.savedImage)
            unavailable = Set(images.filter { !FileManager.default.fileExists(atPath: $0.fileURL.path) }.map(\.id))
            failure = nil
        } catch {
            failure = UserMessage(
                title: String(localized: "Can't open the material catalog"), message: error.localizedDescription)
        }
    }

    /// Saves again the images a failed download or a quit left unsaved (`PendingImageSaves`), while their links may
    /// still serve them. Run once, at launch.
    func resumePendingSaves(now: Date = .now) async {
        let pending: [PendingImage]
        let saved: Set<UUID>
        do {
            pending = try await self.pending.pending()
            saved = Set(try await catalog.materials().filter { $0.current.fileURL != nil }.map(\.id))
        } catch {
            failure = UserMessage(
                title: String(localized: "Can't open the material catalog"), message: error.localizedDescription)
            return
        }
        let ended = pending.filter {
            saved.contains($0.id) || now.timeIntervalSince($0.createdAt) > PendingImage.lifetime
        }
        try? await self.pending.removePending(Set(ended.map(\.id)))
        let images = pending.filter { image in !ended.contains(image) }.map {
            var image = GeneratedImage(
                id: $0.id, url: $0.remoteURL, prompt: $0.prompt, model: $0.model, aspectRatio: $0.aspectRatio)
            image.remote = $0.remote
            image.parameters = $0.parameters
            image.inputImages = $0.inputImages
            image.variantGroupID = $0.variantGroupID
            image.title = $0.title
            return image
        }
        guard !images.isEmpty else { return }
        logger.info("Saving \(images.count, privacy: .public) images left unsaved")
        save(images, createdAt: Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0.createdAt) })) { _, _ in }
    }

    /// Catalog file locations, including prior versions, for retaining access to earlier output folders.
    func storedFiles() async throws -> [URL] {
        try await catalog.materials().flatMap { $0.versions.compactMap(\.fileURL) }
    }

    /// Saves `images` one after another, reporting each one saved; a quit waits for them (`finishSaving`). They are
    /// noted first as pending, so one that can't be saved now is tried again on the next launch.
    func save(
        _ images: [GeneratedImage], createdAt: [UUID: Date] = [:],
        then saved: @escaping (GeneratedImage, SavedImage) -> Void
    ) {
        let id = UUID()
        let now = Date.now
        saves[id] = Task {
            let pending = images.map {
                var image = PendingImage(
                    id: $0.id, remoteURL: $0.url, prompt: $0.prompt, model: $0.model, aspectRatio: $0.aspectRatio,
                    createdAt: createdAt[$0.id] ?? now)
                image.remote = $0.remote
                image.parameters = $0.parameters
                image.inputImages = $0.inputImages
                image.variantGroupID = $0.variantGroupID
                image.title = $0.title
                return image
            }
            do {
                try await self.pending.addPending(pending)
            } catch {
                logger.error("Can't note the images to save: \(String(describing: error), privacy: .private)")
            }
            for image in pending {
                guard let generated = images.first(where: { $0.id == image.id }) else { continue }
                if let file = await saveRetrying(generated, at: image.createdAt) { saved(generated, file) }
            }
            saves[id] = nil
        }
    }

    /// `save`, tried again after a short wait when it fails: most failures are a dropped connection.
    private func saveRetrying(_ generated: GeneratedImage, at date: Date) async -> SavedImage? {
        for wait in [Duration.seconds(2), .seconds(10), nil] {
            if let file = await save(generated, at: date) {
                try? await self.pending.removePending([generated.id])
                return file
            }
            guard let wait else { break }
            try? await Task.sleep(for: wait)
        }
        return nil
    }

    /// Images being saved, or waiting their turn.
    var pendingSaveCount: Int { max(saves.count, imports.count) }

    /// Waits for the images being saved, so a quit doesn't cut off a download whose link expires.
    func finishSaving() async {
        for task in Array(saves.values) { await task.value }
        for task in Array(imports.values) { _ = await task.value }
    }

    /// Downloads `generated` into `folder`, named after its prompt; `nil` when it couldn't be saved, and the image
    /// stays usable from its link for this session.
    @discardableResult
    func save(_ generated: GeneratedImage, at date: Date = .now) async -> SavedImage? {
        let key = generated.remote?.key ?? generated.id.uuidString
        if let inFlight = imports[key] { return await inFlight.value }
        let task = Task { await downloadAndSave(generated, at: date) }
        imports[key] = task
        defer { imports[key] = nil }
        return await task.value
    }

    private func downloadAndSave(_ generated: GeneratedImage, at date: Date) async -> SavedImage? {
        saving.insert(generated.id)
        defer { saving.remove(generated.id) }
        do {
            if let remote = generated.remote, let known = try await catalog.material(remote: remote),
                known.current.availability == .available, let saved = MaterialLibrary.savedImage(known)
            {
                return saved
            }
            let media = try await MediaLinkDownloader().download(
                generated.url, into: layout.generatedImagesFolder, expected: .image)
            defer { try? FileManager.default.removeItem(at: media.fileURL.deletingLastPathComponent()) }
            let folder = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = Self.unusedFile(
                in: folder, baseName: SavedImage.baseName(prompt: generated.title ?? generated.prompt, createdAt: date),
                pathExtension: media.fileURL.pathExtension)
            try FileManager.default.moveItem(at: media.fileURL, to: file)
            var saved = SavedImage(
                id: generated.id, fileURL: file, prompt: generated.prompt, model: generated.model,
                aspectRatio: generated.aspectRatio, createdAt: date, remoteURL: generated.url, title: generated.title)
            do {
                let material = try await catalog.saveImage(
                    saved, remote: generated.remote,
                    generation: MaterialGeneration(
                        prompt: generated.prompt, model: generated.model, parameters: generated.parameters,
                        title: generated.title),
                    inputs: generated.inputImages, variantGroupID: generated.variantGroupID)
                saved = MaterialLibrary.savedImage(material) ?? saved
            } catch {
                // Not listed, so taken back: the next try saves it again instead of leaving a second copy.
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            images.insert(saved, at: 0)
            if let again = images.dropFirst().firstIndex(where: { $0.id == saved.id }) {
                // Keep the controller's in-memory view in step with the catalog.
                images.remove(at: again)
            }
            return saved
        } catch {
            failure = UserMessage(
                title: String(localized: "Can't save this image"), message: error.localizedDescription)
            logger.error("Can't save a generated image: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// Moves the images to the Trash and takes them off the list. An image whose file can't be found is left alone:
    /// it may be on a drive that isn't connected, and only `remove` forgets it. One not saved yet isn't tried again.
    /// An image whose file can't be moved stays listed; the others still go, and then the first failure is thrown.
    func trash(_ ids: Set<UUID>) async throws {
        try? await self.pending.removePending(ids)
        // A run on this Mac would add a version to an image in the Trash: stopped first.
        await onDeviceRuns?.stop(ids)
        // The files of earlier versions in the output folders go too (`MaterialVersions.earlierFiles`), first; none
        // while the delivery sets, which keep theirs, can't be read.
        let materials = (try? await catalog.materials().filter { ids.contains($0.id) }) ?? []
        let held = try? await MaterialVersions.held(by: catalog.deliverySets())
        let owns = outputFolder.owns
        let earlier = Dictionary(
            materials.map { material in
                (material.id, held.map { MaterialVersions.earlierFiles(of: material, held: $0, owns: owns) } ?? [])
            },
            uniquingKeysWith: { first, _ in first })
        var trashed: Set<UUID> = []
        var notTrashed: [any Error] = []
        for image in images where ids.contains(image.id) {
            guard FileManager.default.fileExists(atPath: image.fileURL.path(percentEncoded: false)) else { continue }
            do {
                for file in earlier[image.id] ?? []
                where FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                    try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                }
                try FileManager.default.trashItem(at: image.fileURL, resultingItemURL: nil)
                trashed.insert(image.id)
            } catch {
                logger.error("Can't move an image to the Trash: \(String(describing: error), privacy: .private)")
                notTrashed.append(error)
            }
        }
        try await forget(trashed)
        if let failure = notTrashed.first { throw failure }
    }

    /// Takes the images off the library without touching their files: for images the user no longer expects back.
    func remove(_ ids: Set<UUID>) async throws {
        try await forget(ids)
    }

    /// Stars or unstars the images, keeping them in place; the index keeps the stars.
    func setStarred(_ isStarred: Bool, for ids: Set<UUID>) async throws {
        try await catalog.setMaterialStarred(isStarred, ids: ids)
        for i in images.indices where ids.contains(images[i].id) { images[i].isStarred = isStarred }
    }

    /// Downloads an account image into the library, where it stars, compares and trashes like any saved image.
    /// Returns `nil` when the download couldn't be saved; the account image itself is untouched. An image
    /// imported before is returned as is, and a download in flight is joined: one generation keeps one row.
    @discardableResult
    func importRemote(_ remote: HistoryImageItem, owner: String?) async -> SavedImage? {
        var image = GeneratedImage(
            id: remote.jobID, url: remote.outputURL,
            prompt: remote.prompt, model: remote.model, aspectRatio: remote.aspectRatio)
        image.remote = MaterialRemote(provider: .account, owner: owner, id: remote.id)
        return await save(image, at: remote.createdAt)
    }

    /// Downloads an account image's file for viewing, referencing or comparing, keeping one copy per catalog identity
    /// in the temporary folder. Unlike `save`, it doesn't join the library: the account is still its home.
    func download(_ remote: HistoryImageItem) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "downloaded-images", directoryHint: .isDirectory)
        if let cached = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ).first(where: { $0.deletingPathExtension().lastPathComponent == remote.jobID.uuidString }) {
            return cached
        }
        let media = try await MediaLinkDownloader().download(
            remote.outputURL, into: layout.generatedImagesFolder, expected: .image)
        defer { try? FileManager.default.removeItem(at: media.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: remote.jobID.uuidString).appendingPathExtension(media.fileURL.pathExtension)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: file)
        }
        try FileManager.default.copyItem(at: media.fileURL, to: file)
        return file
    }

    private func forget(_ ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        try await catalog.removeMaterials(ids)
        images.removeAll { ids.contains($0.id) }
        unavailable.subtract(ids)
    }

    /// `folder/<baseName>.<ext>`, or with " 2", " 3"… when that name is taken.
    static func unusedFile(in folder: URL, baseName: String, pathExtension: String) -> URL {
        var number = 1
        while true {
            let name = number == 1 ? baseName : "\(baseName) \(number)"
            let file = folder.appending(path: name, directoryHint: .notDirectory).appendingPathExtension(pathExtension)
            if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
            number += 1
        }
    }
}

extension AppEnvironment {
    /// Saves each image Generate… makes into the library as it arrives, and tells the generator where.
    static func saveGeneratedImages(of generator: ReferenceGenerator, into library: ImageLibrary) {
        generator.onImages = { [weak generator, weak library] images in
            library?.save(images) { image, saved in
                if generator?.contains(image.id) == false {
                    // Deleted from the results while it was downloading.
                    Task { try? await library?.trash([saved.id]) }
                } else {
                    generator?.setFile(saved.fileURL, for: image.id)
                }
            }
        }
    }
}
