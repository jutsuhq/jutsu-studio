import Foundation
import JutsuAgent
import JutsuCore
import MediaKit
import Presentation

// frames: still frames and a contact sheet into the output folder's Exports folder (`FrameGrab.write`). Free; a
// history item's source is read from its Higgsfield link.
extension AgentService {
    func frames(_ fields: FramesCommand) async throws(AgentError) -> AgentFrames {
        defer { discard(fields.files) }
        let byID = fields.item == nil && fields.compareItem == nil ? [:] : try await materialsByID()
        var clips = [try clip(item: fields.item, file: fields.file, in: byID)]
        if let id = fields.compareItem {
            clips.append(try clip(item: id, file: nil, in: byID))
        } else if let path = fields.compareFile {
            clips.append(try clip(item: nil, file: path, in: byID))
        } else if fields.compareSource, let id = fields.item {
            guard case .video(let item)? = byID[id].flatMap(MaterialLibrary.row), let source = item.spec.source else {
                throw .badRequest("frames: compare_source is a video's source clip; this item has none")
            }
            // A source only on Higgsfield (a history item's) is read from its HTTPS link, as the Library plays it.
            guard source.fileURL.isFileURL || source.fileURL.scheme == "https" else {
                throw .badRequest("frames: this item's source clip can't be read from this Mac")
            }
            clips.append(FrameClip(source: source.fileURL, bookmark: source.bookmark, offset: source.range.lowerBound))
        }
        let folder = environment.outputFolder.url(of: .exports)
        try Self.makeFolder(folder)
        let written: WrittenFrames
        do {
            written = try await FrameGrab.write(clips: clips, times: fields.times, into: folder)
        } catch {
            throw Self.agentError(error)
        }
        return AgentFrames(
            folder: folder.path(percentEncoded: false),
            frames: written.frames.map {
                AgentFrames.Frame(
                    clip: $0.clip == 0 ? "main" : "compare", time: $0.time, file: $0.file.path(percentEncoded: false))
            },
            sheet: written.sheet?.path(percentEncoded: false))
    }

    private func materialsByID() async throws(AgentError) -> [UUID: Material] {
        Dictionary(try await materials().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A Library result with a file on this Mac, a video or an image, or a file the helper sent.
    private func clip(item id: UUID?, file path: String?, in byID: [UUID: Material]) throws(AgentError) -> FrameClip {
        if let path { return FrameClip(try inboxFile(path)) }
        let row = id.flatMap { byID[$0] }.flatMap(MaterialLibrary.row)
        let file: URL?
        switch row {
        case .video(let item)? where item.historyItem == nil: file = item.outputFile
        case .localImage(let image)?: file = image.fileURL
        default: file = nil
        }
        guard let file, FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            throw AgentError(
                .notFound, message: "There's no Library item \(id?.uuidString ?? "") with a file on this Mac.",
                retryable: false, next: "Call library_search for the item IDs.")
        }
        return FrameClip(file)
    }

    private static func agentError(_ error: FrameGrabError) -> AgentError {
        let clip = error.clip
        switch error.reason {
        case .pastEnd(let time, let duration):
            return .badRequest(
                "frames: \(time.formatted()) s is past the end of \(clip.name), which runs "
                    + "\(duration.formatted(.number.precision(.fractionLength(0...2)))) s")
        case .unreadable(let reason):
            let role =
                switch clip.role {
                case .video: "video"
                case .image: "image"
                case .sourceVideo: "source video"
                }
            return AgentError(
                .failed, message: "frames: can't read the \(role) \(clip.name): \(reason)", retryable: false,
                next: clip.role == .sourceVideo
                    ? "Check in the Library that the source still plays; if not, frames of the result alone still work."
                    : "Check that the file is a video or an image the app can read.")
        case .notWritten(let reason):
            return AgentError(
                .failed, message: "The frames couldn't be written: \(reason)", retryable: false,
                next: "Check that the file is a video or an image the app can read.")
        }
    }
}
