import AppKit
import JutsuCore
import Persistence
import Presentation
import SwiftData
import SwiftUI
import os

extension LibraryView {
    // MARK: Image rows

    /// The origin's images before any filter, for the "no images yet" state.
    func imagesTotal(in rows: [LibraryMediaItem]) -> Int {
        rows.filter { !$0.isVideo }.count
    }

    /// One image card: a click selects it and clears the results' selection, ⌘-click adds to it, a double click
    /// previews it, and Space previews the first selected one.
    func imageCard(_ row: LibraryMediaItem, in layout: LibraryGridLayout) -> some View {
        // Only the images on screen: a collapsed group's other variants stay selected but aren't acted on.
        let rows = layout.images
        let isSelected = imageSelected.contains(row.id)
        return Group {
            switch row {
            case .video:
                EmptyView()
            case .localImage(let image):
                SavedImageCard(
                    image: image, isSelected: isSelected,
                    isAvailable: !environment.imageLibrary.unavailable.contains(image.id),
                    onDeviceRun: environment.onDevice.run(for: image.id))
            case .remoteImage(let image):
                RemoteImageCard(image: image, isSelected: isSelected)
            }
        }
        .onTapGesture(count: 2) { previewImage(row) }
        .onTapGesture { selectImage(row) }
        .contextMenu {
            let chosen = bulkImages(around: row, in: rows)
            LibraryImageMenu(
                row: row, chosen: chosen, isSelected: isSelected, canSelect: imagePicker == nil,
                unavailable: environment.imageLibrary.unavailable, actions: imageActions)
            cullingMenu(for: (chosen ?? [row]).map(\.id), in: layout)
            variantMenu(for: row.id, in: layout)
        }
        .resultFileDrag(imageDrag(row))
        .onKeyPress(.space) {
            let selected = rows.filter { imageSelected.contains($0.id) }
            previewImage(selected.first ?? row)
            return .handled
        }
    }

    /// The selected images shown, when the card is one of several selected cards: its menu then acts on them all.
    func bulkImages(around row: LibraryMediaItem, in rows: [LibraryMediaItem]) -> [LibraryMediaItem]? {
        guard imagePicker == nil, imageSelected.contains(row.id), imageSelected.count > 1 else { return nil }
        return rows.filter { imageSelected.contains($0.id) }
    }

    func imageDrag(_ row: LibraryMediaItem) -> ResultFile? {
        guard case .localImage(let image) = row,
            !environment.imageLibrary.unavailable.contains(image.id)
        else { return nil }
        return ResultFile(id: image.id, url: image.fileURL)
    }

    var imageActions: LibraryImageActions {
        LibraryImageActions(
            useAsReferences: useAsReferences,
            makeVideo: makeVideo,
            showDetails: { row in imageDetails = catalogReference(of: row.id) },
            quickLook: { quickLookURL = $0 },
            withDownloaded: withDownloaded,
            setStarred: setImageStarred,
            setLiked: setImageLiked,
            compare: compareImage,
            downloadToLibrary: downloadImageToLibrary,
            toggleSelection: { toggleImage($0) },
            clearSelection: { imageSelected = [] },
            trash: { pendingImageTrash = $0 },
            remove: { pendingImageRemoval = $0 },
            report: { exportMessage = $0 },
            editInOtherApp: editInOtherApp, importEditedVersion: importEditedVersion,
            newDeliverySet: newDeliverySet,
            upscaleOnDevice: { image in
                guard let source = catalogReference(of: image.id) else { return }
                onDeviceImage = OnDeviceTarget(
                    kind: .upscaleImage, source: source, file: image.fileURL, title: image.title ?? image.prompt)
            },
            compareWithOriginal: originalImageCompare)
    }

    /// Compare with Original for an image with an earlier version it was made from.
    func originalImageCompare(_ image: SavedImage) -> (() -> Void)? {
        guard let material = catalogMaterial(image.id),
            let pair = MaterialVersions.imagePair(material, current: image, exists: ResultTrash().fileExists)
        else { return nil }
        return {
            imageSelected = []
            comparingImages = pair
        }
    }

    /// Compare with Original for a result with an earlier version it was made from.
    func originalCompare(_ item: LibraryItemModel) -> (() -> Void)? {
        guard let material = catalogMaterial(item.id),
            let pair = MaterialVersions.videoPair(material, current: item, exists: ResultTrash().fileExists)
        else { return nil }
        return { comparing = pair }
    }

    // MARK: Images

    /// A click selects only this image and clears the results; ⌘-click adds to the image selection.
    func selectImage(_ row: LibraryMediaItem) {
        if imagePicker != nil {
            pickImage(row)
            return
        }
        selected.clear()
        cursor = row.id
        hasKeyboard = true
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            toggleImage(row.id)
        } else {
            imageSelected = imageSelected == Set([row.id]) ? [] : [row.id]
        }
    }

    func toggleImage(_ id: UUID) {
        if imageSelected.contains(id) {
            imageSelected.remove(id)
        } else {
            imageSelected.insert(id)
        }
    }

    /// Previews the image's file, downloading an account image first.
    func previewImage(_ row: LibraryMediaItem) {
        switch row {
        case .video:
            return
        case .localImage(let image):
            guard !environment.imageLibrary.unavailable.contains(image.id) else { return }
            quickLookURL = quickLookURL == image.fileURL ? nil : image.fileURL
        case .remoteImage(let image):
            withDownloaded(image) { url in quickLookURL = url }
        }
    }

    /// Runs `action` with the account image's file, downloading it first unless it is already here.
    func withDownloaded(_ image: HistoryImageItem, _ action: @escaping @MainActor (URL) -> Void) {
        if let url = downloadedImages[image.jobID] {
            action(url)
            return
        }
        guard !downloadingImages.contains(image.jobID) else { return }
        downloadingImages.insert(image.jobID)
        Task {
            do {
                let url = try await environment.imageLibrary.download(image)
                downloadedImages[image.jobID] = url
                action(url)
            } catch {
                exportMessage =
                    UserMessage(error, kind: .account)
                    ?? UserMessage(
                        title: String(localized: "Can't download this image"),
                        message: String(localized: "Try again in a moment."))
            }
            downloadingImages.remove(image.jobID)
        }
    }

    /// Starts picking images to compare, with `row` picked; an account image is downloaded first.
    func compareImage(_ row: LibraryMediaItem) {
        guard row.id != imagePicker?.picked.first else { return }
        if imagePicker == nil {
            selected.clear()
            imageSelected = []
            imagePicker = ComparePicker()
        }
        pickImage(row)
    }

    /// Picks the image for the compare: an account image is downloaded first and picked once it's in.
    func pickImage(_ row: LibraryMediaItem) {
        switch row {
        case .video:
            return
        case .localImage(let image):
            guard !environment.imageLibrary.unavailable.contains(image.id) else { return }
            imagePicker?.toggle(image.id)
        case .remoteImage(let image):
            if downloadedImages[image.jobID] != nil {
                imagePicker?.toggle(image.jobID)
            } else {
                withDownloaded(image) { _ in imagePicker?.toggle(image.jobID) }
            }
        }
    }

    /// The two picks as a compare, once both have files.
    func imagePair(from picker: ComparePicker, in rows: [LibraryMediaItem]) -> ImageComparePair? {
        guard picker.picked.count == 2 else { return nil }
        let images = picker.picked.map { id -> CompareImage? in
            guard let row = rows.first(where: { $0.id == id }) else { return nil }
            switch row {
            case .video:
                return nil
            case .localImage(let image):
                return .saved(image)
            case .remoteImage(let image):
                return downloadedImages[image.jobID].map {
                    CompareImage(id: image.jobID, fileURL: $0, prompt: image.prompt)
                }
            }
        }
        guard let left = images[0], let right = images[1] else { return nil }
        return ImageComparePair(left, right)
    }

    /// Opens the images in Create as references, like files opened from Finder.
    func useAsReferences(_ urls: [URL]) {
        navigation.open(urls)
        imageSelected = []
    }

    /// Opens Create's video side with the images, each pinned to its catalog version so the job records what it was
    /// made from; account images are downloaded first, and none goes when one can't be.
    func makeVideo(_ rows: [LibraryMediaItem]) {
        Task {
            var images: [LocalImage] = []
            for row in rows {
                let file: URL
                let prompt: String
                switch row {
                case .video:
                    continue
                case .localImage(let image):
                    (file, prompt) = (image.fileURL, image.prompt)
                case .remoteImage(let image):
                    do {
                        if let downloaded = downloadedImages[image.jobID] {
                            file = downloaded
                        } else {
                            file = try await environment.imageLibrary.download(image)
                        }
                    } catch {
                        exportMessage =
                            UserMessage(error, kind: .account)
                            ?? UserMessage(
                                title: String(localized: "Can't download this image"),
                                message: String(localized: "Try again in a moment."))
                        return
                    }
                    downloadedImages[image.jobID] = file
                    prompt = image.prompt
                }
                guard var image = ReferencesSection.references([file]).first else { continue }
                image.prompt = prompt.isEmpty ? nil : prompt
                image.material = catalogReference(of: row.id)
                images.append(image)
            }
            navigation.makeVideo(from: images)
            imageSelected = []
        }
    }

    /// The current version of the catalog entry behind a grid row; `nil` when it can't be read.
    func catalogReference(of id: UUID) -> MaterialReference? {
        try? records.first { $0.id == id }?.material().reference
    }

    /// The details of an image version, read from the whole catalog while the sheet is open.
    func imageDetailsSheet(_ reference: MaterialReference) -> some View {
        let materials = records.compactMap { try? $0.material() }
        let material = materials.first { $0.id == reference.materialID }
        let row = material.flatMap(MaterialLibrary.row)
        let isAvailable =
            switch row {
            case .localImage(let image)?: !environment.imageLibrary.unavailable.contains(image.id)
            case .remoteImage?: true
            default: false
            }
        return ImageDetailsSheet(
            reference: reference, relations: MaterialRelations(materials),
            openVideo: { id in
                imageDetails = nil
                comparing = nil
                batchSelection = nil
                selection = id
            },
            openImage: { imageDetails = $0 },
            // Make Video takes the current version, so an earlier one shown here doesn't offer it.
            makeVideo: isAvailable && material?.current.id == reference.versionID
                ? row.map { row in { makeVideo([row]) } } : nil,
            quickLook: { quickLookURL = $0 })
    }

    func setImageStarred(_ isStarred: Bool, _ images: [SavedImage]) {
        Task {
            do {
                try await environment.imageLibrary.setStarred(isStarred, for: Set(images.map(\.id)))
            } catch {
                exportMessage = UserMessage(
                    title: String(localized: "Couldn't star the images"),
                    message: error.localizedDescription)
            }
        }
    }

    func setImageLiked(_ isLiked: Bool, _ images: [HistoryImageItem]) {
        Task {
            do {
                try await environment.setImageLiked(isLiked, for: images)
            } catch {
                exportMessage = .likeNotSaved(error)
            }
        }
    }

    /// Downloads the account image into the library, where it behaves like any saved image.
    func downloadImageToLibrary(_ image: HistoryImageItem) {
        Task {
            guard await environment.imageLibrary.importRemote(image, owner: environment.provider?.owner) == nil else {
                return
            }
            exportMessage = UserMessage(
                title: String(localized: "Can't download this image"),
                message: String(localized: "Try again in a moment."))
        }
    }

    func trashImages(_ ids: Set<UUID>) {
        let library = environment.imageLibrary
        Task {
            do {
                try await library.trash(ids)
                imageSelected.subtract(ids)
            } catch {
                // The images that went are off the list; the ones that stayed stay selected.
                imageSelected = Set(imageSelected.filter { id in library.images.contains { $0.id == id } })
                exportMessage = UserMessage(
                    title: String(localized: "Couldn't move the images to the Trash"),
                    message: error.localizedDescription)
            }
        }
    }

    func removeImages(_ ids: Set<UUID>) {
        let library = environment.imageLibrary
        Task {
            do {
                try await library.remove(ids)
                imageSelected.subtract(ids)
            } catch {
                exportMessage = UserMessage(
                    title: String(localized: "Couldn't remove the images from the library"),
                    message: error.localizedDescription)
            }
        }
    }
}
