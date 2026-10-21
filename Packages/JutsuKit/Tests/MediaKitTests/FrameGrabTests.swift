import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import MediaKit

/// The frames tool's still frames and contact sheet, from generated clips.
@Suite struct FrameGrabTests {
    @Test func framesAreTheExactTimesAndTheSheetHasARowPerClip() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = try await Fixtures.makeVideo(in: directory, width: 640, height: 360, seconds: 2)
        #expect(try await FrameGrab.duration(of: video) == 2)
        var frames: [CGImage] = []
        try await FrameGrab.frames(of: video, at: [0, 0.6, 1.4]) { index, image in
            #expect(index == frames.count)
            frames.append(image)
        }
        #expect(frames.map(\.width) == [640, 640, 640])
        let image = try #require(Fixtures.makeImage(in: directory, width: 360, height: 640, type: .png))
        #expect(FrameGrab.isImage(image))
        #expect(!FrameGrab.isImage(video))
        let still = try FrameGrab.still(at: image)
        #expect((still.width, still.height) == (360, 640))

        // Each column is as wide as its widest frame: 640 at 360 high, the portrait still 203.
        let sheet = try #require(FrameGrab.sheet([frames, [still]], cellHeight: 360, gap: 8))
        #expect(sheet.width == 8 + 3 * (640 + 8))
        #expect(sheet.height == 8 + 2 * (360 + 8))
        #expect(FrameGrab.sheet([]) == nil)
    }

    @Test func aPNGIsNeverWrittenOverAFile() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try #require(Fixtures.makeImage(in: directory, width: 64, height: 48, type: .jpeg))
        let still = try FrameGrab.still(at: image)
        let png = directory.appending(path: "frame.png")
        try FrameGrab.writePNG(still, to: png)
        #expect(Fixtures.imageSize(at: png).map { [$0.width, $0.height] } == [64, 48])
        #expect(throws: CocoaError.self) { try FrameGrab.writePNG(still, to: png) }
        #expect(throws: CocoaError.self) { try FrameGrab.writePNG(still, to: image) }
    }

    /// A frame is decoded at most `maximumSide` long, and the sheet keeps only a copy at its cell height.
    @Test func framesAreBoundedAndTheSheetsCopyIsSmall() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = try await Fixtures.makeVideo(in: directory, width: 2880, height: 1620, seconds: 1)
        var sizes: [[Int]] = []
        try await FrameGrab.frames(of: video, at: [0.5]) { _, image in sizes.append([image.width, image.height]) }
        #expect(sizes == [[2048, 1152]])
        // A time at the very end, which frames lets through, is the last frame.
        try await FrameGrab.frames(of: video, at: [1.0]) { _, _ in }
        let image = try #require(Fixtures.makeImage(in: directory, width: 1280, height: 720, type: .png))
        let still = try FrameGrab.still(at: image)
        let small = try #require(FrameGrab.scaled(still, toHeight: FrameGrab.sheetCellHeight))
        #expect((small.width, small.height) == (640, 360))
        #expect(FrameGrab.scaled(small, toHeight: 720) === small)
    }
}
