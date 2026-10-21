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
    /// One clip to take frames of: its file and where its times start. A file the person picked is read through its
    /// bookmark, in scoped access held only while its frames are taken (`writeFrames`), as the Library's player does.
    struct FrameClip: Sendable {
        let url: URL
        let bookmark: Data?
        /// Seconds added to each time asked: the start of the range a source clip's job used.
        let offset: Double
        /// What its frames are named after.
        let name: String
        /// What it is, for an error that says which clip couldn't be read: "video", "source video"…
        let role: String

        init(url: URL, bookmark: Data? = nil, offset: Double = 0, role: String) {
            self.url = url
            self.bookmark = bookmark
            self.offset = offset
            name = url.deletingPathExtension().lastPathComponent
            self.role = role
        }
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
            guard source.fileURL.isFileURL else {
                throw .badRequest("frames: this item's source clip is only on Higgsfield, not on this Mac")
            }
            compare = FrameClip(
                url: source.fileURL, bookmark: source.bookmark, offset: source.range.lowerBound,
                role: "source video")
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
            return FrameClip(url: url, role: FrameGrab.isImage(url) ? "image" : "video")
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
        return FrameClip(url: file, role: FrameGrab.isImage(file) ? "image" : "video")
    }

    /// Takes every frame, then writes them and the sheet under names no file has.
    nonisolated private static func writeFrames(
        main: FrameClip, compare: FrameClip?, times: [Double], into folder: URL
    ) async throws -> AgentFrames {
        let clips = [main] + (compare.map { [$0] } ?? [])
        var rows: [[CGImage]] = []
        for clip in clips {
            let access = SecurityScopedAccess(url: clip.url, bookmark: clip.bookmark)
            let url = access.url
            guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
                throw unreadable(clip, because: "it was moved or deleted, or Jutsu Studio may no longer read it")
            }
            do {
                if FrameGrab.isImage(url) {
                    let still = try FrameGrab.still(at: url)
                    rows.append(times.map { _ in still })
                } else {
                    let at = times.map { $0 + clip.offset }
                    let duration = try await FrameGrab.duration(of: url)
                    if let late = at.first(where: { $0 > duration }) {
                        throw AgentError.badRequest(
                            "frames: \(late.formatted()) s is past the end of \(clip.name), which runs "
                                + "\(duration.formatted(.number.precision(.fractionLength(0...2)))) s")
                    }
                    rows.append(try await FrameGrab.frames(of: url, at: at))
                }
            } catch let error as AgentError {
                throw error
            } catch {
                logger.error("Agent frames can't read a clip: \(String(describing: error), privacy: .private)")
                throw unreadable(clip, because: error.localizedDescription)
            }
            withExtendedLifetime(access) {}
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
        return AgentFrames(folder: folder.path(percentEncoded: false), frames: frames, sheet: sheet)
    }

    /// Which clip couldn't be read, and why.
    nonisolated private static func unreadable(_ clip: FrameClip, because reason: String) -> AgentError {
        AgentError(
            .failed, message: "frames: can't read the \(clip.role) \(clip.name): \(reason)", retryable: false,
            next: clip.role == "source video"
                ? "Check in the Library that the source still plays; if not, frames of the result alone still work."
                : "Check that the file is a video or an image the app can read.")
    }
}
