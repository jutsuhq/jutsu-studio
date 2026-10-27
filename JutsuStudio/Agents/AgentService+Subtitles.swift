import Foundation
import JutsuAgent
import JutsuCore
import Presentation

// subtitles: make (a run followed with jobs), get and export, and the Subtitles sheet show opens for the person. The
// rules are `AgentSubtitleRuns`'; this reads the item and writes the export.
extension AgentService {
    func subtitles(_ fields: SubtitlesCommand, client: String?) async throws(AgentError) -> AgentResponse {
        switch fields.action {
        case .make:
            let created = try await subtitleAgent.make(
                fields, client: client, gate: requests,
                refusals: Self.refusals("subtitles", made: "its run never started"),
                record: { [weak self] ids throws(AgentError) in
                    guard let self else { throw AgentError.agentsOff }
                    try self.recordRequest(
                        fields.requestID ?? "", fingerprint: fields.fingerprint ?? "", jobIDs: ids,
                        kind: AgentOnDeviceRuns.kind)
                },
                target: { [weak self] () throws(AgentError) in
                    guard let self else { throw AgentError.agentsOff }
                    return try await self.subtitleTarget(fields.item)
                })
            return AgentResponse(created: created)
        case .get:
            let target = try await subtitleTarget(fields.item)
            return AgentResponse(
                subtitles: try AgentSubtitleRuns.answer(target.subtitles, of: target.source, format: fields.format))
        case .export:
            return AgentResponse(subtitles: try await exportSubtitles(fields))
        }
    }

    /// Writes the current version's cues into the output folder's Exports folder, never over a file.
    private func exportSubtitles(_ fields: SubtitlesCommand) async throws(AgentError) -> AgentSubtitles {
        let target = try await subtitleTarget(fields.item)
        let format = fields.format ?? .srt
        let answer = try AgentSubtitleRuns.answer(target.subtitles, of: target.source)
        guard let subtitles = target.subtitles else { return answer }
        let folder = environment.outputFolder.url(of: .exports)
        let name = AgentSubtitleRuns.fileName(
            for: target.file, language: subtitles.language, format: format,
            existing: AgentExports.existingNames(in: folder))
        let file = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(AgentSubtitleRuns.text(subtitles, format).utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            throw AgentError(
                .failed, message: "The subtitles can't be written: \(error.localizedDescription)", retryable: true,
                next: "Check that the output folder can be written to, then export again.")
        }
        return try AgentSubtitleRuns.answer(subtitles, of: target.source, file: file)
    }

    /// The video's current version, its file and its subtitles, as the Subtitles sheet would read them.
    private func subtitleTarget(_ id: UUID) async throws(AgentError) -> AgentSubtitleRuns.Target {
        guard case .video(let material, let item, let file) = try await onDeviceItem(id) else {
            throw AgentError(
                .invalidRequest, message: "Subtitles are made of a video's speech; this item is an image.",
                retryable: false, next: "Pick a video's Library ID (library_search with kind video).")
        }
        return AgentSubtitleRuns.Target(
            source: material.reference, file: material.current.fileURL ?? item.outputFile ?? file,
            bookmark: material.current.bookmark, subtitles: material.current.subtitles)
    }

    /// Opens the video's Subtitles sheet over the Library. Refused while the window shows another sheet, which
    /// SwiftUI wouldn't replace; one this opened before is replaced.
    func showSubtitles(for id: UUID) async throws(AgentError) -> AgentShown {
        guard case .video(let material, let item, let file) = try await onDeviceItem(id) else {
            throw AgentError(
                .invalidRequest, message: "The Subtitles sheet is for videos; this item is an image.",
                retryable: false, next: "Pick a video's Library ID.")
        }
        let navigation = environment.navigation
        if navigation.subtitlesSheet == nil, navigation.onDeviceSheet == nil, system.mainWindowHasSheet {
            throw AgentError(
                .needsPerson, message: "The person has a sheet open in Jutsu Studio, so the sheet isn't shown over it.",
                retryable: true, next: "Ask the person to finish or close it, then call show again.")
        }
        navigation.selection = .library
        navigation.onDeviceSheet = nil
        navigation.subtitlesSheet = SubtitleTarget(
            source: material.reference, file: material.current.fileURL ?? file, bookmark: material.current.bookmark,
            title: item.title)
        return AgentShown(page: .library, item: id, sheet: .subtitles)
    }
}
