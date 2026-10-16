import Foundation
import JutsuCore

/// Adapts catalog entries to existing Library cards without maintaining separate image/video stores.
public enum MaterialLibrary {
    public static func row(_ material: Material) -> LibraryMediaItem? {
        guard !material.isHidden else { return nil }
        let version = material.current
        if material.kind == .video, var job = version.video {
            job.outputFile = version.fileURL
            if version.fileURL != nil {
                return .video(LibraryItemModel(job: job, isStarred: material.isStarred))
            }
            guard let remote = material.remote, let url = version.remoteURL else { return nil }
            var history = HistoryItem(
                id: remote.id, jobID: material.id, mode: job.spec.mode, model: job.spec.model,
                createdAt: material.createdAt, isLiked: material.isStarred, outputURL: url,
                duration: job.outputDuration, pixelSize: job.outputMedia?.pixelSize,
                resolution: job.spec.resolution, prompt: version.generation?.prompt ?? "",
                inputs: job.inputs ?? RemoteInputs(video: nil, images: []))
            history.isNativeDraft = job.remote?.isNativeDraft ?? false
            history.draftJobID = job.spec.draftJobID
            return .video(LibraryItemModel(history: history))
        }
        if let image = savedImage(material) { return .localImage(image) }
        guard material.kind == .image, let remote = material.remote, let url = version.remoteURL else { return nil }
        return .remoteImage(
            HistoryImageItem(
                id: remote.id, jobID: material.id, prompt: version.generation?.prompt ?? "",
                model: version.generation?.model ?? "", createdAt: material.createdAt,
                isLiked: material.isStarred, outputURL: url, pixelSize: version.pixelSize))
    }

    public static func savedImage(_ material: Material) -> SavedImage? {
        guard material.kind == .image, let file = material.current.fileURL else { return nil }
        return SavedImage(
            id: material.id, fileURL: file, prompt: material.current.generation?.prompt ?? "",
            model: material.current.generation?.model ?? "", aspectRatio: material.current.aspectRatio,
            createdAt: material.createdAt, remoteURL: material.current.remoteURL, isStarred: material.isStarred)
    }
}
