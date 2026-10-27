import Foundation

/// How a result is re-encoded for an editing timeline. Every preset writes a constant frame rate.
public enum ExportPreset: String, Codable, Sendable, CaseIterable {
    case premiere
    case davinciResolve
    case finalCutPro
    case editingH264

    public enum VideoCodec: String, Codable, Sendable {
        case proRes422
        /// High-bitrate H.264, for editors and machines without ProRes decoding.
        case h264
    }

    public enum AudioCodec: String, Codable, Sendable {
        case linearPCM
        case aac
    }

    public enum Container: String, Codable, Sendable {
        case quickTime
        case mpeg4

        public var fileExtension: String {
            switch self {
            case .quickTime: "mov"
            case .mpeg4: "mp4"
            }
        }
    }

    /// The three NLEs all import ProRes 422 with PCM audio natively on macOS.
    public var videoCodec: VideoCodec {
        switch self {
        case .premiere, .davinciResolve, .finalCutPro: .proRes422
        case .editingH264: .h264
        }
    }

    public var audioCodec: AudioCodec {
        switch videoCodec {
        case .proRes422: .linearPCM
        case .h264: .aac
        }
    }

    public var container: Container {
        switch videoCodec {
        case .proRes422: .quickTime
        case .h264: .mpeg4
        }
    }

    public var fileExtension: String { container.fileExtension }
}

/// One frame's duration as a rational, `value / timescale` seconds.
public struct FrameDuration: Sendable, Hashable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    static let fallback = FrameDuration(value: 1, timescale: 30)
    /// Bases of the NTSC rates, which run at `base * 1000 / 1001` frames per second.
    static let ntscBases: [Int32] = [24, 30, 48, 60, 120]

    /// The constant frame duration for a nominal rate as AVFoundation reports it. NTSC rates
    /// (23.976, 29.97, 59.94…) stay exact as 1001/24000 etc.; rounding them would drift a frame
    /// every ~33 s against the source in a timeline.
    public static func constant(forNominalRate rate: Double) -> FrameDuration {
        guard rate.isFinite, rate >= 1, rate <= 240 else { return fallback }
        for base in ntscBases where abs(rate - Double(base) * 1000 / 1001) < 0.01 {
            return FrameDuration(value: 1001, timescale: base * 1000)
        }
        return FrameDuration(value: 1, timescale: Int32(rate.rounded()))
    }
}

/// How a still image is written for a delivery set: format, size, quality and color space. Video outputs use
/// `ExportPreset`.
public struct ImageExportPreset: Codable, Sendable, Hashable {
    public enum Format: String, Codable, Sendable, CaseIterable {
        case jpeg, png, heic

        public var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .heic: "heic"
            }
        }

        /// The uniform type ImageIO writes.
        public var typeIdentifier: String {
            switch self {
            case .jpeg: "public.jpeg"
            case .png: "public.png"
            case .heic: "public.heic"
            }
        }

        /// Only PNG keeps transparency; JPEG and HEIC are flattened onto the preset's background.
        public var keepsAlpha: Bool { self == .png }
        /// Whether `quality` applies.
        public var isLossy: Bool { self != .png }
    }

    public enum ColorSpace: String, Codable, Sendable, CaseIterable {
        case sRGB, displayP3
    }

    public var format: Format
    /// The long side in pixels after the crop; `nil` keeps the cropped size. Never upscales.
    public var longEdge: Int?
    /// 0…1, for JPEG and HEIC.
    public var quality: Double
    public var colorSpace: ColorSpace
    /// What transparent pixels become in a format without alpha.
    public var background: RGBColor

    public init(
        format: Format, longEdge: Int? = nil, quality: Double = 0.9, colorSpace: ColorSpace = .sRGB,
        background: RGBColor = .white
    ) {
        self.format = format
        self.longEdge = longEdge
        self.quality = quality
        self.colorSpace = colorSpace
        self.background = background
    }

    /// The pixel size written for a cropped picture of `size`: scaled down to `longEdge`, never up.
    public func outputSize(for size: PixelSize) -> PixelSize {
        guard let longEdge, longEdge > 0, size.isValid, max(size.width, size.height) > longEdge else { return size }
        let scale = Double(longEdge) / Double(max(size.width, size.height))
        return PixelSize(
            width: max(1, Int((Double(size.width) * scale).rounded())),
            height: max(1, Int((Double(size.height) * scale).rounded())))
    }
}

/// An opaque color, each component 0…1.
public struct RGBColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    public static let black = RGBColor(red: 0, green: 0, blue: 0)
}

/// What a video output does with the subtitles of each video's version.
public enum DeliverySubtitles: String, Codable, Sendable, CaseIterable {
    /// An `.srt` and a `.vtt` next to the video, under its name, timed as the video is.
    case files
    /// Drawn into the video's frames.
    case burnIn = "burn_in"
}

/// One output of a delivery set: an image or video preset, and the frame every item is cropped to. Image outputs
/// apply to the set's images, video outputs to its videos.
public struct DeliveryOutput: Codable, Sendable, Hashable, Identifiable {
    public enum Preset: Codable, Sendable, Hashable {
        case image(ImageExportPreset)
        case video(ExportPreset)
    }

    public var id: UUID
    /// The output's part of the file names, e.g. "web"; empty uses `summary`.
    public var name: String
    public var preset: Preset
    /// `nil` keeps each item's own frame.
    public var aspect: CropAspect?
    /// A video output's subtitles; `nil` for none, and for an image output.
    public var subtitles: DeliverySubtitles?

    public init(
        id: UUID = UUID(), name: String = "", preset: Preset, aspect: CropAspect? = nil,
        subtitles: DeliverySubtitles? = nil
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.aspect = aspect
        self.subtitles = subtitles
    }

    /// The subtitle files written next to a video of this output: none unless its subtitles are `files`.
    public var subtitleFormats: [SubtitleFormat] {
        kind == .video && subtitles == .files ? SubtitleFormat.allCases : []
    }

    public var kind: Material.Kind {
        switch preset {
        case .image: .image
        case .video: .video
        }
    }

    public var fileExtension: String {
        switch preset {
        case .image(let image): image.format.fileExtension
        case .video(let video): video.fileExtension
        }
    }

    /// "jpg-2048-4x5": what a file name says when the output has no name of its own.
    public var summary: String {
        let format =
            switch preset {
            case .image(let image): [image.format.fileExtension] + [image.longEdge.map(String.init)].compactMap(\.self)
            case .video(let video): [video.rawValue]
            }
        let burned = kind == .video && subtitles == .burnIn ? "subtitled" : nil
        return (format + [aspect?.key, burned].compactMap(\.self)).joined(separator: "-")
    }
}
