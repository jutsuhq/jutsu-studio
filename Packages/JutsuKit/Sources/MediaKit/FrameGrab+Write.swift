import CoreGraphics
import Foundation
import JutsuCore
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "MediaKit")

/// One clip to take frames of: its file and where its times start. A file the person picked is read through its
/// bookmark, in scoped access held only while its frames are taken, as the Library's player does.
public struct FrameClip: Sendable, Hashable {
    /// What the clip is, for an error that says which one couldn't be read.
    public enum Role: Sendable, Hashable {
        case video
        case image
        /// The source clip a result's job used.
        case sourceVideo
    }

    public var url: URL
    public var bookmark: Data?
    /// Seconds added to each time asked: the start of the range a source clip's job used.
    public var offset: Double
    public var role: Role

    /// A result or a file: an image by its extension, else a video.
    public init(_ url: URL, bookmark: Data? = nil) {
        self.url = url
        self.bookmark = bookmark
        offset = 0
        role = FrameGrab.isImage(url) ? .image : .video
    }

    /// The source clip of a result, whose job used it from `offset` seconds on.
    public init(source url: URL, bookmark: Data?, offset: Double) {
        self.url = url
        self.bookmark = bookmark
        self.offset = offset
        role = .sourceVideo
    }

    /// What its frames are named after: the file's name without its extension.
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Why `FrameGrab.write` wrote nothing more, and for which clip.
public struct FrameGrabError: Error, Sendable {
    public enum Reason: Sendable, Hashable {
        /// The clip can't be read: why.
        case unreadable(String)
        /// `time`, in seconds from the start of the file, is past its end at `duration`.
        case pastEnd(time: Double, duration: Double)
        /// A frame was read but couldn't be written: not the clip's fault.
        case notWritten(String)
    }

    public var clip: FrameClip
    public var reason: Reason
}

/// What `FrameGrab.write` wrote.
public struct WrittenFrames: Sendable, Hashable {
    public struct Frame: Sendable, Hashable {
        /// The index of its clip in the clips asked for.
        public var clip: Int
        /// Seconds from the start of the clip's file.
        public var time: Double
        public var file: URL
    }

    /// In the order asked, the first clip's first.
    public var frames: [Frame]
    /// Every frame on one image, a row per clip and a column per time: written for several clips or several times.
    public var sheet: URL?
}

extension FrameGrab {
    /// Writes each clip's frame at each of `times` (plus the clip's offset) into `folder` as PNG files, and for several
    /// clips or several times a contact sheet named after the first clip. Every clip is checked first, that it can be
    /// read and, for a video, runs past every time, so nothing is decoded for a request that fails; then each frame is
    /// written as soon as it is taken, under a name no file has, keeping only a small copy of it for the sheet. An
    /// image gives the same frame at every time.
    public static func write(
        clips: [FrameClip], times: [Double], into folder: URL
    ) async throws(FrameGrabError) -> WrittenFrames {
        var opened: [OpenClip] = []
        for clip in clips { opened.append(try await open(clip, times: times)) }
        var frames: [WrittenFrames.Frame] = []
        var rows: [[CGImage]] = []
        for (index, open) in opened.enumerated() {
            let (written, row) = try await write(open, index: index, times: times, into: folder)
            frames += written
            rows.append(row)
        }
        var sheetURL: URL?
        if let main = clips.first, rows.count > 1 || times.count > 1, let image = sheet(rows) {
            let url = folder.appending(path: "\(main.name) frames.png").unusedFileURL()
            do {
                try writePNG(image, to: url)
            } catch {
                throw FrameGrabError(clip: main, reason: .notWritten(error.localizedDescription))
            }
            sheetURL = url
        }
        withExtendedLifetime(opened) {}
        return WrittenFrames(frames: frames, sheet: sheetURL)
    }

    /// A clip open for reading: in scoped access through its bookmark, held until its frames are written.
    private struct OpenClip {
        let clip: FrameClip
        let access: SecurityScopedAccess
        let isImage: Bool
    }

    /// `clip` in scoped access, once it is known to be readable and, for a video, to run past every time.
    private static func open(_ clip: FrameClip, times: [Double]) async throws(FrameGrabError) -> OpenClip {
        let access = SecurityScopedAccess(url: clip.url, bookmark: clip.bookmark)
        let url = access.url
        guard !url.isFileURL || FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw FrameGrabError(
                clip: clip, reason: .unreadable("it was moved or deleted, or Jutsu Studio may no longer read it"))
        }
        let isImage = Self.isImage(url)
        guard !isImage else { return OpenClip(clip: clip, access: access, isImage: true) }
        let length: Double
        do {
            length = try await duration(of: url)
        } catch {
            throw unreadable(clip, error)
        }
        if let late = times.map({ $0 + clip.offset }).first(where: { $0 > length }) {
            throw FrameGrabError(clip: clip, reason: .pastEnd(time: late, duration: length))
        }
        return OpenClip(clip: clip, access: access, isImage: false)
    }

    /// Writes the clip's frame at each time as soon as it is taken; returns them and their copies for the sheet.
    private static func write(
        _ open: OpenClip, index: Int, times: [Double], into folder: URL
    ) async throws(FrameGrabError) -> (frames: [WrittenFrames.Frame], row: [CGImage]) {
        let clip = open.clip
        var frames: [WrittenFrames.Frame] = []
        var row: [CGImage] = []
        let write = { (time: Double, image: CGImage) throws in
            let at = time + clip.offset
            let name = "\(clip.name) at \(at.formatted(.number.precision(.fractionLength(0...3)))) s.png"
            let url = folder.appending(path: name).unusedFileURL()
            do {
                try writePNG(image, to: url)
            } catch {
                throw WriteFailure(message: error.localizedDescription)
            }
            frames.append(WrittenFrames.Frame(clip: index, time: at, file: url))
            if let small = scaled(image, toHeight: sheetCellHeight) { row.append(small) }
        }
        do {
            if open.isImage {
                guard let still = await ImageThumbnail.image(at: open.access.url, maxPixelSize: maximumSide) else {
                    throw MediaError.unreadableImage
                }
                for time in times { try write(time, still) }
            } else {
                try await self.frames(of: open.access.url, at: times.map { $0 + clip.offset }) { position, image in
                    try write(times[position], image)
                }
            }
        } catch let failure as WriteFailure {
            throw FrameGrabError(clip: clip, reason: .notWritten(failure.message))
        } catch {
            throw unreadable(clip, error)
        }
        return (frames, row)
    }

    /// A frame that was read but couldn't be written.
    private struct WriteFailure: Error {
        let message: String
    }

    private static func unreadable(_ clip: FrameClip, _ error: any Error) -> FrameGrabError {
        logger.error("Can't take frames of a clip: \(String(describing: error), privacy: .private)")
        return FrameGrabError(clip: clip, reason: .unreadable(error.localizedDescription))
    }
}
