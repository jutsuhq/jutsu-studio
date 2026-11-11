import AVFoundation
import Foundation
import JutsuCore

extension MediaPreparer {
    /// The audio types sent as they are, by file extension, with the content type they are uploaded as. Higgsfield's
    /// `media_upload` takes audio by the file name's extension without listing them; these three are the common ones.
    static let passThroughAudio: [String: String] = ["mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4"]

    /// MP3, WAV and M4A are passed through untouched; any other file AVFoundation reads sound from (AIFF, CAF, a
    /// video's soundtrack) is converted to M4A (AAC).
    public func prepareAudio(_ audio: LocalAudio) async throws -> PreparedFile {
        try Task.checkCancellation()
        return try await audio.withAccess { url in
            try await prepareAudio(at: url)
        }
    }

    /// `url` is the recording with access already started.
    private func prepareAudio(at url: URL) async throws -> PreparedFile {
        _ = try await MediaProbe.audioDuration(url)
        let fileExtension = url.pathExtension.lowercased()
        let passThroughType = Self.passThroughAudio[fileExtension]
        let sourceHash = try contentHash(ofFileAt: url)
        let key = ContentHasher.sha256Hex(of: "audio|\(sourceHash)")
        let output = workingDirectory.appendingPathComponent(key)
            .appendingPathExtension(passThroughType == nil ? "m4a" : fileExtension)
        let contentType = passThroughType ?? "audio/mp4"
        if let cached = try cachedFile(at: output, contentType: contentType) {
            return cached
        }

        let partial = try partialURL(for: output)
        defer { try? FileManager.default.removeItem(at: partial) }
        if passThroughType != nil {
            try FileManager.default.copyItem(at: url, to: partial)
        } else {
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw MediaError.exportFailed("No M4A export for this file")
            }
            session.outputURL = partial
            session.outputFileType = .m4a
            try await VideoExport.run(ExportSessionBox(session), progress: { _ in })
        }
        return try finish(partial, as: output, contentType: contentType)
    }
}
