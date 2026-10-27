import Foundation

/// Speech to timed words on-device (`Transcript`), from the sound of a video or audio file only.
public protocol SpeechTranscribing: Sendable {
    /// The models this Mac has and the languages each takes; asks nothing that downloads.
    func availability() async -> SpeechAvailability

    /// Transcribes the sound of `file` in `language` with `model`. A file without sound, or with only silence, throws
    /// `TranscriptionError.noSpeech` before any model is touched.
    /// - Parameter mayDownload: whether the language's model may be downloaded first, as the person agreed to; without
    ///   it a missing model throws `TranscriptionError.modelNeeded`.
    func transcribe(
        _ file: URL, language: String, model: SpeechModel, mayDownload: Bool,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> Transcript
}
