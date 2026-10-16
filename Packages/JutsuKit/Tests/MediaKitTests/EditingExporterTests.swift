import AVFoundation
import Foundation
import JutsuCore
import Testing

@testable import MediaKit

@Suite struct EditingExporterTests {
    private func source(_ url: URL) -> SourceClip {
        SourceClip(fileURL: url, duration: 2, pixelSize: PixelSize(width: 720, height: 480), range: 0...2)
    }

    @Test func proResTakesTheSourceFrameRate() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await Fixtures.makeVideo(in: directory, seconds: 2, frameRate: 30)
        let original = try await Fixtures.makeVideo(in: directory, seconds: 2, frameRate: 25)
        let output = directory.appendingPathComponent("take_v1.mov")

        try await EditingExporter.export(result, source: source(original), preset: .finalCutPro, to: output) { _ in }
        let info = try await MediaProbe.probe(output)

        #expect(info.codec == "apcn")
        #expect(abs(info.frameRate - 25) < 0.5)
        #expect(abs(info.duration - 2) < 0.1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!leftovers.contains { $0.contains(".partial") })
    }

    @Test func h264FallsBackToTheResultFrameRate() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await Fixtures.makeVideo(in: directory, seconds: 2, frameRate: 30)
        let missing = directory.appendingPathComponent("gone.mov")
        let output = directory.appendingPathComponent("take_v1.mp4")

        try await EditingExporter.export(result, source: source(missing), preset: .editingH264, to: output) { _ in }
        let info = try await MediaProbe.probe(output)

        #expect(info.codec == "avc1")
        #expect(abs(info.frameRate - 30) < 0.5)
    }

    @Test func neverReplacesAnExistingFile() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await Fixtures.makeVideo(in: directory, seconds: 1)
        let output = directory.appendingPathComponent("take_v1.mov")
        try Data("keep me".utf8).write(to: output)

        await #expect(throws: (any Error).self) {
            try await EditingExporter.export(result, source: nil, preset: .premiere, to: output) { _ in }
        }
        #expect(try Data(contentsOf: output) == Data("keep me".utf8))
    }
}
