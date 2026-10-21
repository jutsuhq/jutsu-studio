import Foundation
import Testing

@testable import MediaKit

/// The frames tool's files: what `FrameGrab.write` takes, names, refuses and writes, from generated clips.
@Suite struct FrameGrabWriteTests {
    private func name(_ clip: FrameClip, at time: Double) -> String {
        "\(clip.name) at \(time.formatted(.number.precision(.fractionLength(0...3)))) s.png"
    }

    private func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
    }

    /// A source clip's times start where its job's range did, and its frames are named at those times.
    @Test func aSourceClipsTimesStartAtItsOffsetAndTheSheetComesWithAComparison() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = FrameClip(try await Fixtures.makeVideo(in: directory, width: 320, height: 180, seconds: 2))
        let source = FrameClip(
            source: try await Fixtures.makeVideo(in: directory, width: 320, height: 180, seconds: 3), bookmark: nil,
            offset: 1)
        #expect(result.role == .video)

        let written = try await FrameGrab.write(clips: [result, source], times: [0, 1.5], into: output)
        #expect(written.frames.map(\.clip) == [0, 0, 1, 1])
        #expect(written.frames.map(\.time) == [0, 1.5, 1, 2.5])
        #expect(
            written.frames.map(\.file.lastPathComponent)
                == [name(result, at: 0), name(result, at: 1.5), name(source, at: 1), name(source, at: 2.5)])
        #expect(written.sheet?.lastPathComponent == "\(result.name) frames.png")
        #expect(files(in: output).count == 5)

        // Asked again, nothing is written over: each file gets a new name.
        let again = try await FrameGrab.write(clips: [result], times: [0], into: output)
        #expect(again.frames.map(\.file.lastPathComponent) == ["\(result.name) at 0 s 2.png"])
        // One clip at one time needs no sheet.
        #expect(again.sheet == nil)
        #expect(files(in: output).count == 6)
    }

    /// A time past a clip's end, counted from its offset, refuses the request before any frame is taken.
    @Test func aTimePastAClipsEndWritesNothing() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = FrameClip(try await Fixtures.makeVideo(in: directory, width: 320, height: 180, seconds: 2))
        let source = FrameClip(source: result.url, bookmark: nil, offset: 1.5)

        await #expect {
            try await FrameGrab.write(clips: [result, source], times: [0, 1], into: output)
        } throws: { error in
            let error = try #require(error as? FrameGrabError)
            return error.clip == source && error.reason == .pastEnd(time: 2.5, duration: 2)
        }
        #expect(files(in: output).isEmpty)
    }

    /// The error names the clip that couldn't be read, so the agent knows which one to fix.
    @Test func theClipThatCantBeReadIsNamed() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = FrameClip(try await Fixtures.makeVideo(in: directory, width: 320, height: 180, seconds: 1))
        let broken = directory.appending(path: "broken.mp4")
        try Data("not a video".utf8).write(to: broken)
        let gone = FrameClip(source: directory.appending(path: "gone.mp4"), bookmark: nil, offset: 0)

        for clip in [FrameClip(broken), gone] {
            await #expect {
                try await FrameGrab.write(clips: [result, clip], times: [0], into: directory)
            } throws: { error in
                guard let error = error as? FrameGrabError, case .unreadable = error.reason else { return false }
                return error.clip == clip
            }
        }
        #expect(!files(in: directory).contains { $0.hasSuffix(".png") })
    }

    /// An image has one frame whatever the time, and several times get a sheet.
    @Test func anImageGivesTheSameFrameAtEveryTime() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = FrameClip(try #require(Fixtures.makeImage(in: directory, width: 64, height: 48, type: .png)))
        #expect(image.role == .image)

        let written = try await FrameGrab.write(clips: [image], times: [0, 30], into: directory)
        #expect(written.frames.map(\.time) == [0, 30])
        let sizes = written.frames.map { Fixtures.imageSize(at: $0.file).map { [$0.width, $0.height] } }
        #expect(sizes == [[64, 48], [64, 48]])
        #expect(written.sheet != nil)
    }
}
