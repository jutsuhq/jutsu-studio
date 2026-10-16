import Foundation
import HiggsfieldProviders
import JobEngine
import JutsuCore
import MediaKit
import Presentation

extension AppEnvironment {
    /// The clip of `preset` as a local file named after it, downloaded once and kept for the jobs that use it.
    func downloadMotionClip(_ preset: MotionPreset) async throws -> URL {
        let file = try Self.localFile(
            in: layout.motionLibraryFolder, named: [preset.id, preset.name], for: preset.videoURL,
            allowed: ServerFileName.videoExtensions)
        try await MediaLinkDownloader().download(preset.videoURL, to: file, expected: .video)
        return file
    }

    /// A reference image the account uploaded before, as a local file named by its media ID, downloaded once.
    func downloadUpload(_ upload: UploadedFile) async throws -> LocalImage {
        let file = try Self.localFile(
            in: layout.accountMediaFolder, named: [upload.id], for: upload.url, allowed: ServerFileName.imageExtensions)
        try await MediaLinkDownloader().download(upload.url, to: file, expected: .image)
        return LocalImage(fileURL: file)
    }

    /// The images the account uploaded, page by page, for References › From Higgsfield; `nil` without an account.
    func uploadedImagesFeed() -> PagedFeed<UploadedFile>? {
        accountUploads.map { source in
            PagedFeed(failureTitle: String(localized: "Can't load your uploads")) { cursor in
                let page = try await source.uploads(.image, after: cursor)
                return (page.items, page.nextCursor)
            }
        }
    }

    /// The account's elements for References › From Higgsfield; `nil` without an account. While their calls aren't
    /// confirmed they are shown disabled and never fetched.
    func accountElementsModel() -> AccountElementsModel? {
        accountElements.map {
            AccountElementsModel(source: $0, isOffered: HiggsfieldMCPProvider.offersReferenceElements)
        }
    }

    /// Prepares an image of a character set like a reference of a job, then uploads it to the account, for "Save to
    /// Higgsfield…"; `nil` while disconnected.
    func elementUploader() -> (@Sendable (LocalImage) async throws -> RemoteAsset)? {
        guard let provider else { return nil }
        let preparer = MediaPreparer(workingDirectory: layout.sourcesFolder)
        return { image in
            try await provider.upload(try await preparer.prepareImage(image))
        }
    }

    /// Save to Higgsfield… on Create's batch characters: publishes a set through `elements` and records the element on
    /// the draft. `nil` without an account connection that publishes elements.
    func characterSaving(_ elements: AccountElementsModel?, into navigation: NavigationModel) -> CharacterSaving? {
        CharacterSaving(elements: elements, owner: accountElements?.owner, upload: elementUploader()) { saved, images in
            navigation.createDraft.setSavedElement(saved, forCharacterSet: images)
        }
    }

    /// An image of an account element as a local file under its element, downloaded once. It keeps its media, so a
    /// job of the same account names it instead of uploading the file.
    func downloadElementImage(
        _ image: ElementImage, at index: Int, of element: AccountElement
    ) async throws
        -> LocalImage
    {
        let file = try Self.localFile(
            in: layout.accountMediaFolder,
            named: ["elements", element.id, image.media?.id ?? "image-\(index + 1)"], for: image.url,
            allowed: ServerFileName.imageExtensions)
        try await MediaLinkDownloader().download(image.url, to: file, expected: .image)
        return LocalImage(fileURL: file, serverMedia: image.media)
    }

    /// A character sheet as a reference: its copy in Library › Images when there is one, else downloaded once under
    /// `account-media/characters/`. It keeps its job ID as its media, so a job of the same account names the sheet
    /// instead of uploading it.
    func characterReference(_ sheet: CharacterSheet) async throws -> LocalImage {
        let media = ServerMedia(id: sheet.id, url: sheet.imageURL, owner: characterMaker?.owner)
        if let saved = sheet.fileURL, FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)) {
            return LocalImage(fileURL: saved, bookmark: Self.bookmark(for: saved), serverMedia: media)
        }
        let file = try Self.localFile(
            in: layout.accountMediaFolder, named: ["characters", sheet.id], for: sheet.imageURL,
            allowed: ServerFileName.imageExtensions)
        try await MediaLinkDownloader().download(sheet.imageURL, to: file, expected: .image)
        return LocalImage(fileURL: file, serverMedia: media)
    }

    private static func localFile(in folder: URL, named names: [String], for url: URL, allowed: [String]) throws -> URL
    {
        guard let file = ServerFileName.file(in: folder, named: names, extensionOf: url, allowed: allowed) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return file
    }
}
