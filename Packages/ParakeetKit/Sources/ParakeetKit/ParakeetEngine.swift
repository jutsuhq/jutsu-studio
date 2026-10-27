import Darwin
import FluidAudio
import Foundation
import JutsuCore

/// Parakeet Ultra (`ParakeetUltra`) through FluidAudio, from the folder the app downloaded it into: loaded for one run
/// and let go after it, and refused when too little memory is free to load it.
public struct ParakeetEngine: SpeechTranscribing {
    private let folder: URL
    private let isDownloaded: @Sendable () -> Bool

    /// - Parameters:
    ///   - folder: the model's files, as `ParakeetUltra.manifest` lists them.
    ///   - isDownloaded: whether every file is there.
    public init(folder: URL, isDownloaded: @escaping @Sendable () -> Bool) {
        self.folder = folder
        self.isDownloaded = isDownloaded
    }

    public func availability() async -> SpeechAvailability {
        SpeechAvailability(
            languages: [.parakeetUltra: ParakeetUltra.languages],
            installed: [.parakeetUltra: isDownloaded() ? Set(ParakeetUltra.languages) : []])
    }

    public func transcribe(
        _ file: URL, language: String, model: SpeechModel, mayDownload: Bool,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> Transcript {
        let code = SpeechSelection.languageCode(language)
        guard model == .parakeetUltra, ParakeetUltra.languages.contains(code) else {
            throw TranscriptionError.unsupportedLanguage
        }
        guard isDownloaded() else { throw TranscriptionError.modelNotDownloaded }
        let free = Self.freeMemoryMB()
        guard free >= ParakeetUltra.memoryMB else {
            throw TranscriptionError.notEnoughMemory(neededMB: ParakeetUltra.memoryMB, freeMB: free)
        }
        progress(.working(0))
        let models = try AsrModels.loadLocal(from: folder, version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let result: ASRResult
        do {
            try Task.checkCancellation()
            var state = try TdtDecoderState.make()
            result = try await manager.transcribe(file, decoderState: &state, language: Language(rawValue: code))
            await manager.cleanup()
        } catch {
            await manager.cleanup()
            throw error
        }
        progress(.working(1))
        let words = buildWordTimings(from: result.tokenTimings ?? []).compactMap { timing -> TimedWord? in
            let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TimedWord(text: text, start: timing.startTime, end: timing.endTime)
        }
        return Transcript(language: language, model: .parakeetUltra, revision: ParakeetUltra.revision, words: words)
    }

    /// Memory macOS can give a new load without paging out what is in use: free pages (which already count the
    /// speculative ones) and inactive ones. Purgeable pages are left out, as they are counted among the active and
    /// inactive ones already.
    static func freeMemoryMB() -> Int {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return Int.max }
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        return Int((pages * UInt64(getpagesize())) >> 20)
    }
}
