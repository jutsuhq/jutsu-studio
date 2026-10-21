import CoreGraphics
import Foundation
import JutsuAgent
import JutsuCore
import MediaKit
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// frames: still frames and a contact sheet into the output folder's Exports folder, local and free.
extension AgentService {
    /// One clip to take frames of: its file, open to the app while the frames are taken, and where its times start.
    struct FrameClip: Sendable {
        let access: SecurityScopedAccess
        /// Seconds added to each time asked: the start of the range a source clip's job used.
        let offset: Double
        /// What its frames are named after.
        let name: String
    }

    func frames(_ fields: FramesCommand) async throws(AgentError) -> AgentFrames {
        defer { discard(fields.files) }
        let byID = fields.item == nil && fields.compareItem == nil ? [:] : try await materialsByID()
        let main = try clip(item: fields.item, file: fields.file, in: byID)
        var compare: FrameClip?
        if let id = fields.compareItem {
            compare = try clip(item: id, file: nil, in: byID)
        } else if let path = fields.compareFile {
            compare = try clip(item: nil, file: path, in: byID)
        } else if fields.compareSource, let id = fields.item {
            guard case .video(let item)? = byID[id].flatMap(MaterialLibrary.row), let source = item.spec.source else {
                throw .badRequest("frames: compare_source is a video's source clip; this item has none")
            }
            compare = FrameClip(
                access: SecurityScopedAccess(url: source.fileURL, bookmark: source.bookmark),
                offset: source.range.lowerBound, name: source.fileURL.deletingPathExtension().lastPathComponent)
        }
        let folder = environment.outputFolder.url(of: .exports)
        try Self.makeFolder(folder)
        do {
            return try await Self.writeFrames(main: main, compare: compare, times: fields.times, into: folder)
        } catch let error as AgentError {
            throw error
        } catch {
            logger.error("Agent frames failed: \(String(describing: error), privacy: .private)")
            throw AgentError(
                .failed, message: "The frames couldn't be written: \(error.localizedDescription)", retryable: false,
                next: "Check that the file is a video or an image the app can read.")
        }
    }

    private func materialsByID() async throws(AgentError) -> [UUID: Material] {
        Dictionary(try await materials().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A Library result with a file on this Mac, a video or an image, or a file the helper sent.
    private func clip(item id: UUID?, file path: String?, in byID: [UUID: Material]) throws(AgentError) -> FrameClip {
        if let path {
            let url = try inboxFile(path)
            return FrameClip(
                access: SecurityScopedAccess(url: url, bookmark: nil), offset: 0,
                name: url.deletingPathExtension().lastPathComponent)
        }
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
        return FrameClip(
            access: SecurityScopedAccess(url: file, bookmark: nil), offset: 0,
            name: file.deletingPathExtension().lastPathComponent)
    }

    /// Takes every frame, then writes them and the sheet under names no file has.
    nonisolated private static func writeFrames(
        main: FrameClip, compare: FrameClip?, times: [Double], into folder: URL
    ) async throws -> AgentFrames {
        let clips = [main] + (compare.map { [$0] } ?? [])
        var rows: [[CGImage]] = []
        for clip in clips {
            let url = clip.access.url
            if FrameGrab.isImage(url) {
                let still = try FrameGrab.still(at: url)
                rows.append(times.map { _ in still })
                continue
            }
            let at = times.map { $0 + clip.offset }
            let duration = try await FrameGrab.duration(of: url)
            if let late = at.first(where: { $0 > duration }) {
                throw AgentError.badRequest(
                    "frames: \(late.formatted()) s is past the end of \(clip.name), which runs "
                        + "\(duration.formatted(.number.precision(.fractionLength(0...2)))) s")
            }
            rows.append(try await FrameGrab.frames(of: url, at: at))
        }
        var frames: [AgentFrames.Frame] = []
        for (index, (clip, row)) in zip(clips, rows).enumerated() {
            for (time, image) in zip(times, row) {
                let at = time + clip.offset
                let name = "\(clip.name) at \(at.formatted(.number.precision(.fractionLength(0...3)))) s.png"
                let url = folder.appending(path: name).unusedFileURL()
                try FrameGrab.writePNG(image, to: url)
                frames.append(
                    AgentFrames.Frame(
                        clip: index == 0 ? "main" : "compare", time: at, file: url.path(percentEncoded: false)))
            }
        }
        var sheet: String?
        if rows.count > 1 || times.count > 1, let image = FrameGrab.sheet(rows) {
            let url = folder.appending(path: "\(main.name) frames.png").unusedFileURL()
            try FrameGrab.writePNG(image, to: url)
            sheet = url.path(percentEncoded: false)
        }
        withExtendedLifetime(clips) {}
        return AgentFrames(folder: folder.path(percentEncoded: false), frames: frames, sheet: sheet)
    }
}
