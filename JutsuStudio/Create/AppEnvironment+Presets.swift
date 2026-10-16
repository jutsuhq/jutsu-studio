import Foundation
import JutsuCore
import Presentation

extension AppEnvironment {
    /// Queues `spec` and puts its restyle preset on top of the gallery's Recent section.
    /// - Parameters:
    ///   - parentID: the library item the job is made from, if any.
    ///   - batchID: the batch the job belongs to, if any.
    ///   - overCapApproved: the user confirmed going over today's cap.
    @discardableResult
    func enqueue(
        _ spec: JobSpec, parentID: UUID? = nil, batchID: UUID? = nil, overCapApproved: Bool = false
    ) async throws -> Job {
        let job = try await engine.enqueue(
            spec, parentID: parentID, batchID: batchID, overCapApproved: overCapApproved)
        if let presetID = spec.presetID { recordPresetUse(presetID) }
        return job
    }

    private func recordPresetUse(_ id: UUID) {
        let cached = PresetCatalog.cachedPreset(id: id, in: layout.presetCacheFolder)
        let recents = PresetShelf.recordingUse(
            id, recents: PresetShelf.decode(defaults.data(forKey: AppSettings.recentPresetsKey)),
            catalog: cached.map { [$0] } ?? [],
            favorites: PresetShelf.decode(defaults.data(forKey: AppSettings.favoritePresetsKey)))
        defaults.set(PresetShelf.encode(recents), forKey: AppSettings.recentPresetsKey)
    }
}
