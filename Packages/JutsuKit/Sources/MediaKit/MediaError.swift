import Foundation

public enum MediaError: Error, Sendable, Equatable {
    /// No video track AVFoundation can decode, e.g. WebM. The user has to convert the file first.
    case unsupportedFormat
    /// ImageIO can't read the file as an image.
    case unreadableImage
    /// The selected range is empty or lies outside the file.
    case invalidRange
    /// Export or encoding failed; carries the underlying error's description.
    case exportFailed(String)
    /// Even the re-encode at the computed bitrate came out over the upload limit.
    case tooLarge(byteCount: Int64)
    /// This Mac's VideoToolbox has no engine for an on-device enhancement, or it won't take this file's frames.
    case engineUnavailable
}

extension MediaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            String(localized: "This video's format can't be read. Convert it to MP4 or MOV first.", bundle: .module)
        case .unreadableImage:
            String(localized: "This image can't be read. Save it as JPEG or PNG and add it again.", bundle: .module)
        case .invalidRange:
            String(localized: "The selected range lies outside the video. Select it again.", bundle: .module)
        case .exportFailed(let detail):
            String(localized: "The file couldn't be converted: \(detail)", bundle: .module)
        case .tooLarge(let byteCount):
            String(
                localized: """
                    Even re-encoded, this video is \(Self.size(byteCount)), over the \
                    \(Self.size(MediaPreparer.fileLengthLimit)) upload limit. Select a shorter range.
                    """, bundle: .module)
        case .engineUnavailable:
            String(localized: "This Mac can't do this to this file.", bundle: .module)
        }
    }

    private static func size(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
