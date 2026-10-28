import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import JutsuCore

#if canImport(os)
    import os

    private let logger = Logger(subsystem: "com.jutsustudio", category: "AccountHistory")
#endif

/// `show_generations` pages in the app's terms: finished videos of the models the app runs, with their inputs.
enum HistoryMapping {
    static func page(_ page: GenerationPage) -> HistoryPage {
        logSkippedModels(page.items)
        return HistoryPage(
            items: page.items.compactMap(item), images: page.items.compactMap(image),
            nextCursor: page.nextCursor.flatMap(cursor))
    }

    /// `nil` for anything the app can't show or run again: other media types and models, unfinished
    /// generations, and inputs without a source video, except for a model that makes clips without one (not in
    /// Edit) and a Style run's, whose input roles are unconfirmed. Kling 4.0 comes back in the mode its
    /// `params.mode` names (`jobMode`), and a clip from frames with them as frames (`frames(of:)`). Only https URLs count: the app downloads them and runs
    /// them again. A Style job is `type: "image"` until it completes and `"video"` once it has, so only a
    /// completed one, a video, is kept, like every other job.
    static func item(_ generation: PastGeneration) -> HistoryItem? {
        let video = generation.media.lazy.compactMap(asset(.video)).first
        guard generation.type == GenerationType.video.rawValue, generation.status == "completed",
            let output = generation.outputURL, output.isHTTPS,
            case (let catalogMode, let videoModel)? = kind(ofModel: generation.model)
        else { return nil }
        let mode = jobMode(of: generation, model: videoModel) ?? catalogMode
        guard video != nil || (mode != .edit && (mode == .restyle || videoModel.makesClipsWithoutSource)) else {
            return nil
        }
        let frames = video == nil && videoModel.declares(.frames) ? self.frames(of: generation) : nil
        let size = generation.width.flatMap { width in generation.height.map { PixelSize(width: width, height: $0) } }
        var history = HistoryItem(
            id: generation.id, mode: mode, model: videoModel, createdAt: generation.createdAt,
            isLiked: generation.isLiked, outputURL: output, duration: generation.duration, pixelSize: size,
            resolution: generation.resolution.flatMap(Resolution.init(rawValue:)), prompt: generation.prompt,
            inputs: RemoteInputs(video: video, images: frames ?? generation.media.compactMap(asset(.image))))
        history.referencesAreFrames = frames != nil
        // Only Seedance 2.5 has a native draft and its finalize (`models_explore get`, 2026-10-15).
        if VideoRequest.Model(rawValue: generation.model) == .seedance25 {
            history.isNativeDraft = generation.isDraft
            history.draftJobID = generation.draftJobID
        }
        return history
    }

    /// The job mode a generation's `params.mode` names, for a model whose one server model runs several of the
    /// app's (Kling 4.0's `video-edit` is Edit, its other modes Motion Transfer); `nil` to keep the catalog's.
    static func jobMode(of generation: PastGeneration, model: VideoModel) -> Mode? {
        guard model.descriptor.shape == .kling4, let mode = generation.mode else { return nil }
        return mode == VideoRequest.kling4VideoEdit ? .edit : .motionTransfer
    }

    /// The start and, when there is one, end frame of a clip made from frames, in that order: the inputs with those
    /// roles, or for Kling 4.0's `image-to-video` its first two images; `nil` for a clip made otherwise.
    static func frames(of generation: PastGeneration) -> [RemoteAsset]? {
        let start = generation.media.compactMap(asset(.startFrame))
        if let first = start.first { return [first] + generation.media.compactMap(asset(.endFrame)).prefix(1) }
        guard generation.mode == VideoRequest.kling4ImageToVideo else { return nil }
        let images = generation.media.compactMap(asset(.image))
        return images.isEmpty ? nil : Array(images.prefix(2))
    }

    /// A server model ID in the app's terms, by the catalog (`AccountModel.constrainedJobs`); `nil` for a model the
    /// app doesn't run. A Style run goes through `execute_preset`, so its ID names no catalog model.
    static func kind(ofModel id: String) -> (Mode, VideoModel)? {
        if let job = AccountModel.constrainedJobs[VideoRequest.Model(rawValue: id)] { return (job.mode, job.model) }
        return id == styleModel ? (.restyle, .genjutsu) : nil
    }

    /// A completed image generation as the library shows it; `nil` for anything else. The model ID is kept as
    /// reported: the app runs no image model by catalog, so there is nothing to map it to.
    static func image(_ generation: PastGeneration) -> HistoryImageItem? {
        guard generation.type == GenerationType.image.rawValue, generation.status == "completed",
            let output = generation.outputURL, output.isHTTPS
        else { return nil }
        let size = generation.width.flatMap { width in generation.height.map { PixelSize(width: width, height: $0) } }
        return HistoryImageItem(
            id: generation.id, prompt: generation.prompt, model: generation.model, createdAt: generation.createdAt,
            isLiked: generation.isLiked, outputURL: output, pixelSize: size)
    }

    /// The cursors of the video and image pages as one: each stream pages on its own. `nil` past both last pages.
    /// Tagged, so a server cursor that happens to be an array never reads as a packed one.
    static func joinedCursor(video: HistoryCursor?, image: HistoryCursor?) -> HistoryCursor? {
        guard video != nil || image != nil else { return nil }
        let values: [JSONValue] = [
            .string(cursorTag), video.flatMap(cursorValue) ?? .null, image.flatMap(cursorValue) ?? .null,
        ]
        return cursor(.array(values))
    }

    static let cursorTag = "jutsu-history-cursors-v1"

    /// The two streams' cursors packed by `joinedCursor`, each `nil` past its last page. Anything else decodes as
    /// a video-only cursor from before images were listed, so old in-flight loads keep working.
    static func splitCursor(_ cursor: HistoryCursor?) -> (video: JSONValue?, image: JSONValue?) {
        guard let value = cursor.flatMap(cursorValue) else { return (nil, nil) }
        guard case .array(let values) = value, values.count == 3, values[0] == .string(cursorTag) else {
            return (value, nil)
        }
        return (values[1] == .null ? nil : values[1], values[2] == .null ? nil : values[2])
    }

    /// The `model` of a Genjutsu Style (`execute_preset`) job, as `job_status` and `jobs_wait` showed it in a live
    /// run on 2026-10-15 (issue #21). Neither history tool listed that job, so a Style from history is rare.
    static let styleModel = "restyle"

    /// Each video model ID a page skips, once, so a model the app doesn't know yet shows up in the log. Only the ID
    /// is logged, nothing else about the generation.
    private static func logSkippedModels(_ generations: [PastGeneration]) {
        #if canImport(os)
            let skipped = Set(
                generations.lazy.filter { $0.type == GenerationType.video.rawValue && kind(ofModel: $0.model) == nil }
                    .map(\.model))
            for model in skipped.sorted() {
                logger.notice("Skipped history videos of the unknown model \(model, privacy: .public)")
            }
        #endif
    }

    /// Inputs without an https URL can't be probed or uploaded again, so they are left out.
    private static func asset(_ role: MediaRole) -> (PastMedia) -> RemoteAsset? {
        { media in
            guard media.role == role, let url = media.url, url.isHTTPS else { return nil }
            return RemoteAsset(url: url, id: media.id)
        }
    }

    /// The cursor as JSON text, so it goes back exactly as it came.
    static func cursor(_ value: JSONValue) -> HistoryCursor? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return HistoryCursor(String(decoding: data, as: UTF8.self))
    }

    static func cursorValue(_ cursor: HistoryCursor) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(cursor.value.utf8))
    }
}
