import Foundation
import JutsuAgent
import JutsuCore
import MediaKit
import Persistence
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// export: Export for Editing's own writer, run in the app as an operation agents follow with jobs.
extension AgentService {
    /// Starts Export for Editing of the videos asked for, into the output folder's Exports folder under names no file
    /// has. It runs in the app (`AgentOperations`); the answer comes at once, or once it finished within `waitSeconds`.
    func exportForEditing(_ fields: ExportCommand) async throws(AgentError) -> AgentExported {
        let preset = Self.preset(fields.preset)
        let folder = environment.outputFolder.url(of: .exports)
        try Self.makeFolder(folder)
        let byID = Dictionary(
            try await materials().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var videos: [LibraryItemModel] = []
        var skipped: [AgentExportFile] = []
        for id in fields.items {
            guard let material = byID[id], case .video(let item)? = MaterialLibrary.row(material),
                item.historyItem == nil, let file = item.outputFile,
                FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
            else {
                skipped.append(
                    AgentExportFile(item: id, status: .skipped, message: "Not a video with a file on this Mac."))
                continue
            }
            videos.append(item)
        }
        let names = AgentExports.editingNames(
            for: videos, preset: preset, existing: AgentExports.existingNames(in: folder))
        let order = Dictionary(fields.items.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sidecar = fields.sidecar ?? true
        let started = operations.start(
            .export, folder: folder.path(percentEncoded: false), total: fields.items.count
        ) { report in
            var files = skipped
            for file in skipped { report(file) }
            for (item, name) in zip(videos, names) {
                let file = await Self.write(item, as: name, preset: preset, into: folder, sidecar: sidecar)
                report(file)
                files.append(file)
            }
            // In the order asked.
            return .success(files.sorted { (order[$0.item] ?? 0) < (order[$1.item] ?? 0) })
        }
        let timedOut = await waitFor(started.id, seconds: fields.waitSeconds ?? 0)
        return AgentExported(job: (operations.operation(started.id) ?? started).job, timedOut: timedOut)
    }

    private static func preset(_ preset: AgentExportPreset) -> ExportPreset {
        switch preset {
        case .premiere: .premiere
        case .davinciResolve: .davinciResolve
        case .finalCutPro: .finalCutPro
        case .editingH264: .editingH264
        }
    }

    /// Writes one take as Export for Editing does, under a name no file has.
    private static func write(
        _ item: LibraryItemModel, as name: ExportNaming.Names, preset: ExportPreset, into folder: URL,
        sidecar writesSidecar: Bool
    ) async -> AgentExportFile {
        guard let result = item.outputFile else {
            return AgentExportFile(item: item.id, status: .skipped, message: "Not a video with a file on this Mac.")
        }
        let video = folder.appending(path: name.video)
        let sidecar = writesSidecar ? folder.appending(path: name.sidecar) : nil
        do {
            let sidecarError = try await EditingExportModel.write(
                preset, item: item, result: result, to: video, sidecar: sidecar)
            return AgentExportFile(
                item: item.id, status: .done, file: video.path(percentEncoded: false),
                sidecar: sidecarError == nil ? sidecar?.path(percentEncoded: false) : nil,
                message: sidecarError.map { "The JSON sidecar wasn't written: \($0.localizedDescription)" })
        } catch {
            logger.error("Agent export failed: \(String(describing: error), privacy: .private)")
            return AgentExportFile(item: item.id, status: .failed, message: error.localizedDescription)
        }
    }
}
