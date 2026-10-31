import Foundation
import JutsuCore
import MediaKit
import Persistence
import Presentation

/// Enhance's runs on this Mac (`OnDeviceRuns`): VideoToolbox does the work, the catalog takes each result as a new
/// version of the item it was started on.
extension AppEnvironment {
    /// Clears what runs before a crash or a quit left in `scratches` first, before any run can start: the Videos
    /// folder of every output folder the app knows, as a run's scratch is the one current when it started. The image
    /// library stops the runs on the images it trashes.
    static func onDeviceRuns(
        store: SwiftDataStore, imageLibrary: ImageLibrary, defaults: UserDefaults, scratches: [URL]
    ) -> OnDeviceRuns {
        for scratch in scratches { OnDeviceRuns.removeLeftovers(in: scratch) }
        let runs = OnDeviceRuns(engine: OnDeviceEnhancer(), consent: OnDeviceModelConsent(defaults: defaults)) {
            request, file, output in
            // Not onto an item deleted meanwhile: the run takes its file back (`OnDeviceRuns`).
            try await store.addEditedVersion(
                of: request.source, file: file, media: output.outputMedia, relists: false)
            await imageLibrary.load()
        }
        imageLibrary.onDeviceRuns = runs
        return runs
    }

    /// Starts `action` on `file`, the file of the exact version `source`. The result goes in the output folder's
    /// Videos, or Images for an image; it is written in Videos first under a hidden name, which `onDeviceRuns`
    /// clears on the next launch after a crash.
    func startOnDevice(_ action: OnDeviceAction, source: MaterialReference, file: URL) {
        let videos = outputFolder.url(of: .videos)
        let destination = action.engine == .imageSuperResolution ? outputFolder.url(of: .images) : videos
        onDevice.start(
            OnDeviceRuns.Request(
                source: source, file: file, action: action, destination: destination, scratch: videos))
    }
}
