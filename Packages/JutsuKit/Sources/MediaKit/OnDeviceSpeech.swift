import AVFoundation
import Foundation
import JutsuCore

/// The app's speech models behind one port (`SpeechTranscribing`): it reads only the file's sound, ends a file without
/// any at once, and keeps each transcript by the file's content, language, model and model revision, so the same
/// file heard again costs nothing. The built-in models are its own; Parakeet comes from the app.
public final class OnDeviceSpeech: SpeechTranscribing {
    private let cache: TranscriptCache
    private let hashes: FileHashCache
    private let parakeet: (any SpeechTranscribing)?

    /// - Parameters:
    ///   - cacheFolder: where transcripts are kept, a few kilobytes each.
    ///   - hashes: the content hashes of files already read.
    ///   - parakeet: Parakeet Ultra's engine, which hears `SpeechModel.parakeetUltra`; `nil` without it.
    public init(cacheFolder: URL, hashes: FileHashCache, parakeet: (any SpeechTranscribing)? = nil) {
        cache = TranscriptCache(folder: cacheFolder)
        self.hashes = hashes
        self.parakeet = parakeet
    }

    public func availability() async -> SpeechAvailability {
        var availability = await BuiltInSpeech.availability()
        if let parakeet {
            let other = await parakeet.availability()
            availability.languages[.parakeetUltra] = other.languages[.parakeetUltra]
            availability.installed[.parakeetUltra] = other.installed[.parakeetUltra]
        }
        return availability
    }

    public func transcribe(
        _ file: URL, language: String, model: SpeechModel, mayDownload: Bool,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> Transcript {
        guard try SoundCheck.hasSound(file) else { throw TranscriptionError.noSpeech }
        let revision = model.isBuiltIn ? BuiltInSpeech.revision : ParakeetUltra.revision
        let hash = try hashes.hash(ofFileAt: file, compute: ContentHasher.sha256Hex(ofFileAt:))
        let key = SpeechSelection.cacheKey(contentHash: hash, language: language, model: model, revision: revision)
        if let cached = cache.transcript(for: key) { return cached }
        let words: [TimedWord]
        if model.isBuiltIn {
            words = try await BuiltInSpeech.transcribe(
                file, language: language, model: model, mayDownload: mayDownload, progress: progress)
        } else if let parakeet {
            words = try await parakeet.transcribe(
                file, language: language, model: model, mayDownload: false, progress: progress
            ).words
        } else {
            throw TranscriptionError.modelNotDownloaded
        }
        guard !words.isEmpty else { throw TranscriptionError.noSpeech }
        let transcript = Transcript(language: language, model: model, revision: revision, words: words)
        cache.store(transcript, for: key)
        return transcript
    }
}

/// Whether a file has sound to hear.
enum SoundCheck {
    /// Quieter than this, about -60 dBFS, is silence.
    static let threshold: Float = 0.001

    /// Reads the sound track until its first sample above silence: `false` for a file without one, or with only
    /// silence. Throws `TranscriptionError.cantOpenFile` for a file that is missing or that the app may not read.
    static func hasSound(_ file: URL) throws -> Bool {
        do {
            try FileHandle(forReadingFrom: file).close()
        } catch {
            throw TranscriptionError.cantOpenFile
        }
        guard let audio = try? AVAudioFile(forReading: file), audio.length > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1 << 16)
        else { return false }
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            guard (try? audio.read(into: buffer)) != nil, buffer.frameLength > 0 else { return false }
            guard let channels = buffer.floatChannelData else { return true }
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
                if samples.contains(where: { abs($0) > threshold }) { return true }
            }
        }
        return false
    }
}

/// Transcripts as JSON files named by their cache key; the oldest go once there are more than `capacity`.
final class TranscriptCache: @unchecked Sendable {
    private let folder: URL
    private let capacity: Int
    private let lock = NSLock()

    init(folder: URL, capacity: Int = 200) {
        self.folder = folder
        self.capacity = capacity
    }

    func transcript(for key: String) -> Transcript? {
        lock.withLock {
            guard let data = try? Data(contentsOf: file(key)) else { return nil }
            return try? JSONDecoder().decode(Transcript.self, from: data)
        }
    }

    func store(_ transcript: Transcript, for key: String) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(transcript) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file(key), options: .atomic)
            prune()
        }
    }

    private func file(_ key: String) -> URL {
        folder.appending(path: "\(key).json", directoryHint: .notDirectory)
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys)),
            files.count > capacity
        else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }
        for (old, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - capacity) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
