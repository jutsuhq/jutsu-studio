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
            // A source only on Higgsfield (a history item's) is read from its HTTPS link, as the Library plays it.
            guard source.fileURL.isFileURL || source.fileURL.scheme == "https" else {
                throw .badRequest("frames: this item's source clip can't be read from this Mac")
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

    /// A clip open for reading: in scoped access through its bookmark, held until its frames are written.
    private struct OpenClip {
        let clip: FrameClip
        let access: SecurityScopedAccess
        let isImage: Bool
    }

    /// Checks every clip first, that it can be read and runs long enough, so nothing is decoded for a request that
    /// fails; then writes each frame as soon as it is taken, under a name no file has, keeping only a small copy of
    /// it for the sheet.
    nonisolated private static func writeFrames(
        main: FrameClip, compare: FrameClip?, times: [Double], into folder: URL
    ) async throws -> AgentFrames {
        var opened: [OpenClip] = []
        for clip in [main] + (compare.map { [$0] } ?? []) {
            opened.append(try await open(clip, times: times))
        }
        var frames: [AgentFrames.Frame] = []
        var rows: [[CGImage]] = []
        for (index, open) in opened.enumerated() {
            let (written, row) = try await writeFrames(
                of: open, label: index == 0 ? "main" : "compare", times: times, into: folder)
            frames += written
            rows.append(row)
        }
        var sheet: String?
        if rows.count > 1 || times.count > 1, let image = FrameGrab.sheet(rows) {
            let url = folder.appending(path: "\(main.name) frames.png").unusedFileURL()
            try FrameGrab.writePNG(image, to: url)
            sheet = url.path(percentEncoded: false)
        }
        withExtendedLifetime(opened) {}
        return AgentFrames(folder: folder.path(percentEncoded: false), frames: frames, sheet: sheet)
    }

    /// `clip` in scoped access, once it is known to be readable and, for a video, to run past every time.
    nonisolated private static func open(_ clip: FrameClip, times: [Double]) async throws -> OpenClip {
        let access = SecurityScopedAccess(url: clip.url, bookmark: clip.bookmark)
        let url = access.url
        guard !url.isFileURL || FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw unreadable(clip, because: "it was moved or deleted, or Jutsu Studio may no longer read it")
        }
        let isImage = FrameGrab.isImage(url)
        guard !isImage else { return OpenClip(clip: clip, access: access, isImage: true) }
        let duration: Double
        do {
            duration = try await FrameGrab.duration(of: url)
        } catch {
            logger.error("Agent frames can't read a clip: \(String(describing: error), privacy: .private)")
            throw unreadable(clip, because: error.localizedDescription)
        }
        if let late = times.map({ $0 + clip.offset }).first(where: { $0 > duration }) {
            throw AgentError.badRequest(
                "frames: \(late.formatted()) s is past the end of \(clip.name), which runs "
                    + "\(duration.formatted(.number.precision(.fractionLength(0...2)))) s")
        }
        return OpenClip(clip: clip, access: access, isImage: false)
    }

    /// Writes the clip's frame at each time as soon as it is taken; returns them and their copies for the sheet.
    nonisolated private static func writeFrames(
        of open: OpenClip, label: String, times: [Double], into folder: URL
    ) async throws -> (frames: [AgentFrames.Frame], row: [CGImage]) {
        let clip = open.clip
        var frames: [AgentFrames.Frame] = []
        var row: [CGImage] = []
        let write = { (time: Double, image: CGImage) throws in
            let at = time + clip.offset
            let name = "\(clip.name) at \(at.formatted(.number.precision(.fractionLength(0...3)))) s.png"
            let url = folder.appending(path: name).unusedFileURL()
            do {
                try FrameGrab.writePNG(image, to: url)
            } catch {
                throw WriteFailure(error: error)
            }
            frames.append(AgentFrames.Frame(clip: label, time: at, file: url.path(percentEncoded: false)))
            if let small = FrameGrab.scaled(image, toHeight: FrameGrab.sheetCellHeight) { row.append(small) }
        }
        do {
            if open.isImage {
                let still = try FrameGrab.still(at: open.access.url, maxPixelSize: FrameGrab.maximumSide)
                for time in times { try write(time, still) }
            } else {
                try await FrameGrab.frames(of: open.access.url, at: times.map { $0 + clip.offset }) { position, image in
                    try write(times[position], image)
                }
            }
        } catch let failure as WriteFailure {
            throw failure.error
        } catch {
            logger.error("Agent frames can't read a clip: \(String(describing: error), privacy: .private)")
            throw unreadable(clip, because: error.localizedDescription)
        }
        return (frames, row)
    }

    /// A frame that was read but couldn't be written: not the clip's fault.
    private struct WriteFailure: Error {
        let error: any Error
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
