import Foundation
import JutsuCore
import MediaKit
import Testing
import UniformTypeIdentifiers

@Suite struct AudioPreparerTests {
    /// WAV is sent as it is; the speech's length is read from the file.
    @Test func passesWAVThroughAndReadsItsLength() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = try Fixtures.makeTone(in: directory, seconds: 2.5, fileExtension: "wav")
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let file = try await preparer.prepareAudio(LocalAudio(fileURL: tone, duration: 2.5))

        #expect(file.contentType == "audio/wav")
        #expect(file.fileURL.pathExtension == "wav")
        #expect(try Data(contentsOf: file.fileURL) == Data(contentsOf: tone))
        #expect(abs(try await MediaProbe.audioDuration(tone) - 2.5) < 0.05)
    }

    /// Another type is converted to M4A, as long as the original.
    @Test func convertsCAFToM4A() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = try Fixtures.makeTone(in: directory, seconds: 2, fileExtension: "caf")
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let file = try await preparer.prepareAudio(LocalAudio(fileURL: tone, duration: 2))

        #expect(file.contentType == "audio/mp4")
        #expect(file.fileURL.pathExtension == "m4a")
        #expect(abs(try await MediaProbe.audioDuration(file.fileURL) - 2) < 0.1)
    }

    /// A file without sound isn't a speech recording.
    @Test func refusesAFileWithoutSound() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try #require(Fixtures.makeImage(in: directory, width: 64, height: 64, type: .png))

        await #expect(throws: MediaError.unsupportedFormat) { try await MediaProbe.audioDuration(image) }
    }
}
