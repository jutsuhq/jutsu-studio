import AVFoundation
import Foundation
import JutsuCore
import Testing

@testable import MediaKit

@Suite struct OnDeviceSpeechTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "OnDeviceSpeech-\(UUID())")

    /// A second of mono sound at 16 kHz: silence, or a quiet tone.
    private func sound(_ name: String, amplitude: Float) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<16000 { samples[index] = amplitude * sin(Float(index) * 0.1) }
        try file.write(from: buffer)
        return url
    }

    @Test func silenceAndAFileWithoutSoundHaveNothingToHear() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try !SoundCheck.hasSound(sound("silence.caf", amplitude: 0)))
        #expect(try SoundCheck.hasSound(sound("tone.caf", amplitude: 0.05)))
        let notSound = folder.appending(path: "note.txt")
        try Data("text".utf8).write(to: notSound)
        #expect(try !SoundCheck.hasSound(notSound))
    }

    @Test func aFileItCantOpenIsntTakenForSilence() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let speech = OnDeviceSpeech(cacheFolder: folder.appending(path: "cache"), hashes: FileHashCache())
        let missing = folder.appending(path: "missing.caf")

        #expect(throws: TranscriptionError.cantOpenFile) { try SoundCheck.hasSound(missing) }
        await #expect(throws: TranscriptionError.cantOpenFile) {
            try await speech.transcribe(
                missing, language: "en-US", model: .transcriber, mayDownload: false, progress: { _ in })
        }
    }

    @Test func silenceEndsAtOnceWithNoSpeech() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let speech = OnDeviceSpeech(cacheFolder: folder.appending(path: "cache"), hashes: FileHashCache())
        let silence = try sound("silence.caf", amplitude: 0)

        await #expect(throws: TranscriptionError.noSpeech) {
            try await speech.transcribe(
                silence, language: "en-US", model: .transcriber, mayDownload: false, progress: { _ in })
        }
    }

    @Test func theCacheKeepsTranscriptsByKeyAndDropsTheOldest() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = TranscriptCache(folder: folder, capacity: 2)
        let transcript = Transcript(
            language: "en-US", model: .dictation, revision: "1", words: [TimedWord(text: "Hi", start: 0, end: 0.4)])

        cache.store(transcript, for: "a")
        #expect(cache.transcript(for: "a") == transcript)
        #expect(cache.transcript(for: "b") == nil)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: folder.appending(path: "a.json").path)
        cache.store(transcript, for: "b")
        cache.store(transcript, for: "c")
        #expect(cache.transcript(for: "a") == nil)
        #expect(cache.transcript(for: "c") == transcript)
    }
}
