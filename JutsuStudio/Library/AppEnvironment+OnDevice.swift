import Foundation
import JutsuCore
import MediaKit
import Persistence
import Presentation

/// Enhance's runs on this Mac (`OnDeviceRuns`): VideoToolbox does the work, the catalog takes each result as a new
/// version of the item it was started on.
extension AppEnvironment {
    /// Clears what runs before a crash or a quit left in `scratches` first, before any run can start: the Videos
    /// folder of every output folder the app knows, as a run's scratch is the one current when it started.
    static func onDeviceRuns(
        store: SwiftDataStore, imageLibrary: ImageLibrary, defaults: UserDefaults, scratches: [URL]
    ) -> OnDeviceRuns {
        for scratch in scratches { OnDeviceRuns.removeLeftovers(in: scratch) }
        return OnDeviceRuns(engine: OnDeviceEnhancer(), consent: OnDeviceModelConsent(defaults: defaults)) {
            request, file, output in
            try await store.addEditedVersion(of: request.source, file: file, media: output.outputMedia)
            await imageLibrary.load()
        }
    }

    /// Starts `action` on `file`, the file of the exact version `source`. The result goes in the output folder's
    /// Videos; it is written there first under a hidden name, which `onDeviceRuns` clears on the next launch after a
    /// crash.
    func startOnDevice(_ action: OnDeviceAction, source: MaterialReference, file: URL) {
        let videos = outputFolder.url(of: .videos)
        onDevice.start(
            OnDeviceRuns.Request(source: source, file: file, action: action, destination: videos, scratch: videos))
    }
}
