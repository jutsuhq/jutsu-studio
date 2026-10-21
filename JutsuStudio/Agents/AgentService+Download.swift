import Foundation
import JutsuAgent
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// library_download: From Higgsfield's own download, free and never spending.
extension AgentService {
    // MARK: library_download

    /// From Higgsfield's download, one result at a time: a video through `importHistory`, an image through the image
    /// library's `importRemote`. Both keep the item's ID; neither spends.
    func libraryDownload(_ fields: LibraryDownloadCommand) async throws(AgentError) -> AgentDownloads {
        let plan = AgentLibraryDownload.plan(fields.ids, in: try await materials())
        if let index = plan.firstIndex(of: .missing) {
            throw AgentError(
                .notFound, message: "There's no Library item \(fields.ids[index].uuidString); nothing was downloaded.",
                retryable: false, next: "Call library_search with include_higgsfield for the item IDs.")
        }
        var items: [AgentDownload] = []
        for (id, target) in zip(fields.ids, plan) {
            switch target {
            case .local(let file):
                items.append(AgentDownload(id: id, status: .alreadyHere, file: file.path(percentEncoded: false)))
            case .video(let history):
                do {
                    let job = try await environment.importHistory(history)
                    items.append(
                        AgentDownload(id: id, status: .downloaded, file: job.outputFile?.path(percentEncoded: false)))
                } catch {
                    items.append(AgentDownload(id: id, status: .failed, message: error.localizedDescription))
                }
            case .image(let remote):
                if let saved = await environment.imageLibrary.importRemote(remote, owner: environment.provider?.owner) {
                    items.append(
                        AgentDownload(id: id, status: .downloaded, file: saved.fileURL.path(percentEncoded: false)))
                } else {
                    items.append(AgentDownload(id: id, status: .failed, message: "The image couldn't be saved."))
                }
            case .missing:
                break
            }
        }
        logger.info("Agent downloaded \(items.count(where: { $0.status == .downloaded }), privacy: .private) item(s)")
        return AgentDownloads(items: items)
    }
}
