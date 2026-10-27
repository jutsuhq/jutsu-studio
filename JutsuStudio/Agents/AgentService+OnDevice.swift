import Foundation
import JutsuAgent
import JutsuCore
import MediaKit
import Presentation

// enhance on this Mac (smooth_motion, upscale with engine mac), its runs in jobs and job_action, and the sheet show
// opens for the person's agreement to a model download. The rules are `AgentOnDeviceRuns`'; this reads the item.
extension AgentService {
    func enhanceOnDevice(_ fields: EnhanceCommand, client: String?) async throws(AgentError) -> AgentCreated {
        try await onDeviceAgent.enhance(
            fields, client: client, gate: requests, refusals: Self.refusals("enhance", made: "its run never started"),
            record: { [weak self] ids throws(AgentError) in
                guard let self else { throw AgentError.agentsOff }
                try self.recordRequest(
                    fields.requestID, fingerprint: fields.fingerprint, jobIDs: ids, kind: AgentOnDeviceRuns.kind)
            },
            target: { [weak self] () throws(AgentError) in
                guard let self else { throw AgentError.agentsOff }
                return try await self.onDeviceTarget(fields.item)
            })
    }

    /// The item's current version and its file, as the sheet would start a run on it.
    private func onDeviceTarget(_ id: UUID) async throws(AgentError) -> AgentOnDeviceRuns.Target {
        let videos = environment.outputFolder.url(of: .videos)
        switch try await onDeviceItem(id) {
        case .video(let material, _, let file):
            let info = try? await MediaProbe.probe(file)
            return AgentOnDeviceRuns.Target(
                source: material.reference, file: file,
                media: info.map { .video($0.pixelSize, frameRate: $0.frameRate, duration: $0.duration) }
                    ?? .unreadableVideo,
                destination: videos, scratch: videos)
        case .image(let material, let image):
            return AgentOnDeviceRuns.Target(
                source: material.reference, file: image.fileURL, media: .image(ImageThumbnail.size(at: image.fileURL)),
                destination: environment.outputFolder.url(of: .images), scratch: videos)
        }
    }

    enum OnDeviceItem {
        case video(Material, LibraryItemModel, URL)
        case image(Material, SavedImage)
    }

    /// A video or image of the Library with its file on this Mac.
    func onDeviceItem(_ id: UUID) async throws(AgentError) -> OnDeviceItem {
        let material = try await materials().first { $0.id == id }
        switch material.flatMap(MaterialLibrary.row) {
        case .video(let item)? where !item.needsImport:
            if let material, let file = item.outputFile { return .video(material, item, file) }
        case .localImage(let image)?:
            if let material { return .image(material, image) }
        default:
            break
        }
        throw AgentError(
            .notFound, message: "There's no video or image \(id.uuidString) with a file on this Mac.",
            retryable: false, next: "Call library_search for the item IDs; library_download brings one from Higgsfield."
        )
    }

    func actOnDevice(_ action: AgentJobAction, _ id: UUID) async throws(AgentError) -> AgentActed {
        guard action == .cancel else {
            throw AgentError(
                .notApplicable, message: "A run on this Mac can only be canceled.", retryable: false,
                next: "Send the request again with a new request_id for another run.")
        }
        if subtitleAgent.knows(id) { return AgentActed(action: action, job: try await subtitleAgent.cancel(id)) }
        return AgentActed(action: action, job: try await onDeviceAgent.cancel(id))
    }

    /// Opens the item's sheet over the Library: Upscale on This Mac, where the person agrees to the model download.
    /// Refused on a Mac without the engine, and while the window shows another sheet, which SwiftUI wouldn't replace;
    /// one this opened before is replaced.
    func showSheet(_ sheet: AgentSheet, for id: UUID) async throws(AgentError) -> AgentShown {
        if sheet == .subtitles { return try await showSubtitles(for: id) }
        let target: OnDeviceTarget
        let action: OnDeviceAction
        switch try await onDeviceItem(id) {
        case .video(let material, let item, let file):
            target = OnDeviceTarget(kind: .upscaleVideo, source: material.reference, file: file, title: item.title)
            action = .upscaleVideo
        case .image(let material, let image):
            target = OnDeviceTarget(
                kind: .upscaleImage, source: material.reference, file: image.fileURL,
                title: image.title ?? image.prompt)
            action = .upscaleImage
        }
        if let refusal = onDeviceAgent.sheetRefusal(action) { throw refusal }
        let navigation = environment.navigation
        if navigation.onDeviceSheet == nil, system.mainWindowHasSheet {
            throw AgentError(
                .needsPerson, message: "The person has a sheet open in Jutsu Studio, so the sheet isn't shown over it.",
                retryable: true, next: "Ask the person to finish or close it, then call show again.")
        }
        navigation.selection = .library
        navigation.onDeviceSheet = target
        return AgentShown(page: .library, item: id, sheet: sheet)
    }
}
