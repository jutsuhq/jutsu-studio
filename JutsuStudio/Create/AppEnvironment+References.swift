import Foundation
import HiggsfieldProviders
import JobEngine
import JutsuCore
import MediaKit
import Presentation

extension AppEnvironment {
    /// Why Generate… is off on this connection; `nil` when it can open.
    var referenceGenerationBlocker: String? {
        guard let provider = imageProvider else { return nil }
        if provider.kind == .account && !HiggsfieldMCPProvider.offersImageGeneration {
            return PostOperationText.waitingForCatalog
        }
        return nil
    }

    /// A new connection: the old one's upload, price and requests are dropped from Generate…, and the requests of the
    /// new connection's account still running are followed again.
    func followImageJobs() {
        referenceGenerator.reset()
        if let provider = imageProvider { referenceGenerator.resume(provider: provider) }
    }

    /// Why the prices and jobs of image requests can't be written down, with the job IDs only this launch knows;
    /// `nil` while they can.
    var unsavedRecords: (reason: String, jobIDs: [String])? {
        let errors = [imageSpend.saveError, referenceGenerator.jobLog.saveError, characterBuilder.log.saveError]
        guard let error = errors.compactMap(\.self).first else { return nil }
        return (
            error.localizedDescription, referenceGenerator.jobLog.unsavedIDs + characterBuilder.log.unsavedIDs
        )
    }

    /// Writes the logs of image requests again after a failed write.
    func retrySavingRecords() {
        imageSpend.retrySave()
        referenceGenerator.jobLog.retrySave()
        characterBuilder.log.retrySave()
    }

    /// Hands the connection's image models to the Generate… sheet. Keyed on `providerGeneration`. The list saved at
    /// the last load shows at once, so the form doesn't wait for the account's catalog at launch.
    func loadImageModels() async {
        guard let provider = imageProvider, referenceGenerationBlocker == nil else {
            referenceGenerator.useModels([])
            return
        }
        let key = AppSettings.imageModelsKey(kind: provider.kind, owner: provider.owner)
        if let saved = defaults.data(forKey: key) {
            referenceGenerator.useSavedModels((try? JSONDecoder().decode([ImageModel].self, from: saved)) ?? [])
        }
        do {
            let models = try await provider.imageModels()
            try Task.checkCancellation()
            referenceGenerator.useModels(models)
            defaults.set(try? JSONEncoder().encode(models), forKey: key)
        } catch is CancellationError {
            return
        } catch {
            referenceGenerator.useModels([], unavailableReason: UserMessage(error)?.message)
        }
    }

    /// Prepares an image to edit like a reference of a job, then uploads it to `provider`.
    func imageUploader(_ provider: any ImageProvider) -> @Sendable (LocalImage) async throws -> RemoteAsset {
        let preparer = MediaPreparer(workingDirectory: layout.sourcesFolder)
        return { image in
            try await provider.upload(try await preparer.prepareImage(image))
        }
    }

    /// Downloads a generated image into `generated/`, which Clear Cache empties, as a reference that remembers its
    /// link and prompt.
    func downloadGenerated(_ image: GeneratedImage) async throws -> LocalImage {
        // Saved in Library › Images already: the reference is that file, so it isn't downloaded twice.
        if let file = image.fileURL, FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            return LocalImage(
                fileURL: file, bookmark: AppEnvironment.bookmark(for: file), remoteOrigin: image.url,
                prompt: image.prompt)
        }
        let media = try await MediaLinkDownloader().download(
            image.url, into: layout.generatedImagesFolder, expected: .image, progress: { _ in })
        return LocalImage(
            fileURL: media.fileURL, bookmark: AppEnvironment.bookmark(for: media.fileURL), remoteOrigin: image.url,
            prompt: image.prompt)
    }

    /// Downloads `image` and adds it to Create's references like an opened file; the message says why it wasn't
    /// added.
    func addGenerated(_ image: GeneratedImage, to navigation: NavigationModel) async -> UserMessage? {
        do {
            let reference = try await downloadGenerated(image)
            if let message = navigation.createDraft.addOpenedReferences([reference]) { return message }
            referenceGenerator.markPicked(image.id)
            return nil
        } catch {
            return UserMessage(error)
        }
    }
}
