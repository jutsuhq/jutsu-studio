import Foundation
import JutsuCore

/// A probed source video as the Create screen shows it. The app fills it from `MediaProbe`.
public struct SourceVideo: Sendable, Hashable, Codable {
    public var fileURL: URL
    /// Length of the whole file, in seconds.
    public var duration: TimeInterval
    public var pixelSize: PixelSize
    /// FourCC of the video codec, e.g. `avc1`.
    public var codec: String
    public var fileSize: Int64
    /// Security-scoped bookmark of `fileURL`, carried into the job's `SourceClip`.
    public var bookmark: Data?
    /// The `https:` link the file was downloaded from, carried into the job's `SourceClip`.
    public var remoteOrigin: URL?

    public init(
        fileURL: URL, duration: TimeInterval, pixelSize: PixelSize, codec: String, fileSize: Int64,
        bookmark: Data? = nil, remoteOrigin: URL? = nil
    ) {
        self.fileURL = fileURL
        self.duration = duration
        self.pixelSize = pixelSize
        self.codec = codec
        self.fileSize = fileSize
        self.bookmark = bookmark
        self.remoteOrigin = remoteOrigin
    }

    public var name: String {
        fileURL.isFileURL ? fileURL.lastPathComponent : String(localized: "Source on Higgsfield", bundle: .module)
    }

    /// Anything but H.264 in MP4 is transcoded before upload, which takes noticeably longer.
    public var needsConversion: Bool { codec != "avc1" || fileURL.pathExtension.lowercased() != "mp4" }

    public var sizeText: String { "\(pixelSize.width)×\(pixelSize.height)" }

    /// "186 MB · HEVC".
    public var fileText: String {
        // A remote file's size isn't probed.
        guard fileURL.isFileURL else { return codecName }
        let megabytes = max(1, Int((Double(fileSize) / 1_000_000).rounded()))
        let size = String(localized: "\(AppSettings.decimal(Double(megabytes), fractionDigits: 0)) MB", bundle: .module)
        return "\(size) · \(codecName)"
    }

    public var codecName: String {
        switch codec {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": "ProRes"
        default: codec.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }
}

extension UserMessage {
    public static let unsupportedVideo = UserMessage(
        title: String(localized: "Convert this video first", bundle: .module),
        message: String(
            localized: "macOS can't play this format (WebM and similar). Export it as MP4 or MOV and add it again.",
            bundle: .module))
}

/// How much of the range a draft renders.
public enum DraftLength: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case wholeRange
    case firstFiveSeconds

    public static let shortSeconds: TimeInterval = 5

    public var id: Self { self }

    public var title: String {
        switch self {
        case .wholeRange: String(localized: "Whole range", bundle: .module)
        case .firstFiveSeconds: String(localized: "First 5 s", bundle: .module)
        }
    }
}

extension AudioOption {
    /// The audio switch label.
    public var title: String {
        switch self {
        case .original: String(localized: "Original", bundle: .module)
        case .mute: String(localized: "Mute", bundle: .module)
        case .fadeOut: String(localized: "Fade out", bundle: .module)
        case .generated: String(localized: "Generated", bundle: .module)
        }
    }
}

extension SeedanceBitrate {
    /// Seedance's Quality picker label.
    public var title: String {
        switch self {
        case .standard: String(localized: "Standard", bundle: .module)
        case .high: String(localized: "High bitrate", bundle: .module)
        }
    }
}

extension CharacterOrientation {
    /// Kling's "Character faces" picker label.
    public var title: String {
        switch self {
        case .image: String(localized: "As in image", bundle: .module)
        case .video: String(localized: "As in video", bundle: .module)
        }
    }
}

extension Mode {
    /// The mode switch label.
    public var shortTitle: String {
        switch self {
        case .motionTransfer: String(localized: "Motion", bundle: .module)
        case .restyle: String(localized: "Restyle", bundle: .module)
        case .objectSwap: String(localized: "Swap", bundle: .module)
        case .edit: String(localized: "Edit", bundle: .module)
        case .extend: String(localized: "Extend", bundle: .module)
        }
    }

    public var tagline: String {
        switch self {
        case .motionTransfer:
            String(localized: "Move your characters, products or clothes with motion from any clip.", bundle: .module)
        case .restyle: String(localized: "Redraw the whole clip in one of the catalog styles.", bundle: .module)
        case .objectSwap: String(localized: "Replace an object in the clip with your own item.", bundle: .module)
        case .edit: String(localized: "Change a clip as the prompt says, with Seedance 2.5.", bundle: .module)
        case .extend: String(localized: "Continue a clip past its last frame, with Seedance 2.5.", bundle: .module)
        }
    }

    public var referencesTitle: String {
        switch self {
        case .motionTransfer: String(localized: "Characters", bundle: .module)
        case .restyle: String(localized: "Character refs", bundle: .module)
        case .objectSwap: String(localized: "Replacement objects", bundle: .module)
        case .edit, .extend: String(localized: "References", bundle: .module)
        }
    }

    public var referencesHint: String {
        switch self {
        case .motionTransfer: String(localized: "Characters, products or clothes", bundle: .module)
        case .restyle: String(localized: "Optional, keeps faces consistent", bundle: .module)
        case .objectSwap: String(localized: "The item to put in the clip", bundle: .module)
        case .edit, .extend: String(localized: "Optional, for faces, products or a look", bundle: .module)
        }
    }

    /// The prompt's placeholder. Images are numbered in order, which is how the prompt names them.
    public var promptHint: String {
        switch self {
        case .motionTransfer:
            String(localized: "Say who moves, e.g. “Image 1 dances on a rooftop at night”", bundle: .module)
        case .restyle: String(localized: "Refine the look, e.g. “warm sunset light, film grain”", bundle: .module)
        case .objectSwap:
            String(
                localized: "Say what changes, e.g. “Replace the car with Image 1, keep the rest of the shot”",
                bundle: .module)
        case .edit:
            String(localized: "What should change? e.g. “Make it night, with rain on the street”", bundle: .module)
        case .extend:
            String(localized: "What happens next? e.g. “She turns around and walks to the door”", bundle: .module)
        }
    }
}
