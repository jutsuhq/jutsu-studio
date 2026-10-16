import Foundation

/// Turns the user's files into files the API accepts. Results are cached by content,
/// so preparing the same input again is cheap.
public protocol MediaPreparing: Sendable {
    /// Trims the selected range, transcodes to MP4 H.264/AAC within the size limit,
    /// and upscales when the clip allows it.
    func prepareVideo(
        _ source: SourceClip, progress: @escaping @Sendable (Double) -> Void
    ) async throws
        -> PreparedFile
    /// Converts to JPEG or PNG and downscales oversized images.
    func prepareImage(_ image: LocalImage) async throws -> PreparedFile
    /// Writes the downloaded `result` to `output` with its sound as `spec.audio` asks (`AudioPlan`),
    /// without re-encoding the video. Returns `false` and writes nothing when the result stays as it is.
    func restoreAudio(of spec: JobSpec, result: URL, to output: URL) async throws -> Bool
    /// The image's size as it shows, upright (its orientation applied); `nil` when it can't be read.
    func imageSize(of image: LocalImage) async -> PixelSize?
    /// A downloaded result's length and upright frame size, read from the file; `nil` when it can't be read.
    func outputMedia(of file: URL) async -> OutputMedia?
}
