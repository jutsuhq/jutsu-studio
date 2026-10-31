import Foundation

/// What an on-device Enhance run makes from the item it was started on (`OnDeviceEnhancing`).
public enum OnDeviceAction: Sendable, Hashable {
    case smoothMotion(SmoothMotion)
    /// A clip up to 720p at `target`, 4× its frame size or less (`OnDeviceUpscale`).
    case upscaleVideo(OnDeviceUpscale.Target)
    /// An image up to 1920×1080 at `target`, 4× its size or less (`OnDeviceUpscale.offersImage`).
    case upscaleImage(OnDeviceUpscale.Target)

    /// The engine the action runs on.
    public var engine: OnDeviceEngine {
        switch self {
        case .smoothMotion: .frameRateConversion
        case .upscaleVideo: .videoSuperResolution
        case .upscaleImage: .imageSuperResolution
        }
    }

    /// What the result's file name adds to the source's: "rooftop 60fps.mp4", "rooftop 4x.mp4", "rooftop 1080p.mp4".
    public var fileSuffix: String {
        switch self {
        case .smoothMotion(.fps60): "60fps"
        case .smoothMotion(.slowMotion2x): "slow 2x"
        case .smoothMotion(.slowMotion4x): "slow 4x"
        case .upscaleVideo(let target), .upscaleImage(let target): target.fileSuffix
        }
    }

    /// The size an upscale ends at; `nil` for another run.
    public var upscaleTarget: OnDeviceUpscale.Target? {
        switch self {
        case .smoothMotion: nil
        case .upscaleVideo(let target), .upscaleImage(let target): target
        }
    }
}

/// VideoToolbox's frame processors, which on-device Enhance runs on.
public enum OnDeviceEngine: String, CaseIterable, Sendable, Hashable {
    /// Makes frames between a clip's own (Smooth Motion).
    case frameRateConversion
    /// Super resolution of the video kind, which uses the frames before to keep detail steady.
    case videoSuperResolution
    /// Super resolution of the image kind, one picture at a time.
    case imageSuperResolution

    /// Whether the engine needs a model macOS downloads once (about 62 MB a kind) before its first run. Merely
    /// setting the engine up for a size starts that download, so it is done only once the person has agreed.
    public var downloadsModel: Bool {
        switch self {
        case .frameRateConversion: false
        case .videoSuperResolution, .imageSuperResolution: true
        }
    }
}

/// Upscale › On this Mac: 4× the frame size with VideoToolbox's super resolution, whose only factor is 4.
public enum OnDeviceUpscale {
    public static let scale = 4
    /// The largest frame the scaler takes, landscape: wider or taller frames are refused, portrait 720p included.
    public static let scalerLimit = PixelSize(width: 1920, height: 1080)

    /// How the scaler takes frames of one size.
    public struct Plan: Sendable, Hashable {
        /// The frames as the scaler gets them: the source's, or turned a quarter when only that way they fit.
        public var scalerInput: PixelSize
        public var rotates: Bool
        /// 4× the source, in its own orientation.
        public var output: PixelSize
    }

    /// The largest video offered, either way round (`offersVideo`).
    public static let videoLimit = PixelSize(width: 1280, height: 720)

    /// Video sources up to 720p either way round: at 1080p the 4× frames ran a 16 GB Mac out of memory (#13).
    public static func offersVideo(_ size: PixelSize) -> Bool {
        size.isValid && max(size.width, size.height) <= videoLimit.width
            && min(size.width, size.height) <= videoLimit.height
    }

    /// Images up to 1920×1080 either way round. The image kind takes 1920 a side in both orientations, so an image
    /// is never turned; the 1080 side keeps a 4× picture's memory in bounds.
    public static func offersImage(_ size: PixelSize) -> Bool {
        size.isValid && max(size.width, size.height) <= scalerLimit.width
            && min(size.width, size.height) <= scalerLimit.height
    }

    /// Frames of `size` as they are when they fit `limit`, else turned a quarter; `nil` when neither way fits.
    public static func plan(for size: PixelSize, limit: PixelSize = scalerLimit) -> Plan? {
        guard size.isValid else { return nil }
        let output = PixelSize(width: size.width * scale, height: size.height * scale)
        if size.width <= limit.width, size.height <= limit.height {
            return Plan(scalerInput: size, rotates: false, output: output)
        }
        guard size.height <= limit.width, size.width <= limit.height else { return nil }
        return Plan(scalerInput: PixelSize(width: size.height, height: size.width), rotates: true, output: output)
    }
}

extension OnDeviceUpscale {
    /// The size an upscale on this Mac ends at: the scaler's own 4×, or that scaled down to a delivery size with the
    /// source's shape. A 720p portrait clip at 4× is 2880×5120, and agents scaled such results to 1080×1920 with
    /// tools of their own (#38).
    public enum Target: Sendable, Hashable {
        /// The scaler's own 4×.
        case full
        /// The short side this many pixels: 1080 (1080p), 1440 (2k) or 2160 (4k).
        case shortSide(Int)
        /// This many times the source's sides, more than 1 and less than 4.
        case factor(Double)

        /// What `init(name:)` takes, for an agent.
        public static let names = "1080p, 2k, 4k, or a factor more than 1 and at most 4 such as 2x or 2.5x"

        /// "1080p", "2k", "4k" or a factor such as "2x" or "2.5x" (more than 1, at most 4); `nil` for anything else.
        public init?(name: String) {
            switch name.lowercased() {
            case "1080p": self = .shortSide(1080)
            case "2k": self = .shortSide(1440)
            case "4k": self = .shortSide(2160)
            case let factor where factor.hasSuffix("x"):
                guard let value = Double(factor.dropLast()), value.isFinite, value > 1, value <= Double(scale) else {
                    return nil
                }
                self = value == Double(scale) ? .full : .factor(value)
            default: return nil
            }
        }

        /// What the result's file name adds: "4x", "1080p", "2k", "4k", "2.5x".
        public var fileSuffix: String {
            switch self {
            case .full: "\(scale)x"
            case .shortSide(1440): "2k"
            case .shortSide(2160): "4k"
            case .shortSide(let side): "\(side)p"
            case .factor(let value): "\(value == value.rounded() ? String(Int(value)) : String(value))x"
            }
        }

        /// The result's size for frames of `source`, in their orientation: the source's shape with even sides, the
        /// short side exactly the one asked for. `nil` when that isn't larger than the source or needs more than 4×.
        public func output(for source: PixelSize) -> PixelSize? {
            guard source.isValid else { return nil }
            let factor: Double
            switch self {
            case .full: return PixelSize(width: source.width * scale, height: source.height * scale)
            case .factor(let value): factor = value
            case .shortSide(let side): factor = Double(side) / Double(min(source.width, source.height))
            }
            guard factor > 1, factor <= Double(scale) else { return nil }
            let even = { (side: Int) in min(Int((Double(side) * factor / 2).rounded()) * 2, side * scale) }
            return PixelSize(width: even(source.width), height: even(source.height))
        }
    }
}

/// The video codec of an on-device result: the clip's own where it can hold the frame, else HEVC.
public enum EnhanceCodec: String, Sendable, Hashable {
    case h264
    case hevc

    /// H.264 holds frames up to 4096 pixels a side; HEVC takes larger ones and any source that isn't H.264.
    public static func of(output: PixelSize, sourceIsH264: Bool) -> EnhanceCodec {
        sourceIsH264 && max(output.width, output.height) <= 4096 ? .h264 : .hevc
    }
}

/// How long an on-device run takes, from the benchmark on an Apple silicon Mac (#13), for the sheet to say before it
/// starts. Rough: other work on the Mac slows a run down.
public enum OnDeviceEstimate {
    /// The first run starts the engine, which took up to about 10 seconds.
    static let engineStart: TimeInterval = 10

    /// 50 ms a source frame at 480p, growing with the pixel count to the power 0.6: larger frames took less than
    /// their pixels would say, 80 ms at 720p in the benchmark (#13) and 130 ms at 1080p in the app's own run.
    /// Encoding included.
    public static func smoothMotion(duration: TimeInterval, frameRate: Double, pixelSize: PixelSize) -> TimeInterval {
        let pixels = Double(max(pixelSize.width * pixelSize.height, 0))
        let perFrame = 0.05 * pow(pixels / Double(854 * 480), 0.6)
        return engineStart + max(duration, 0) * max(frameRate, 1) * perFrame
    }

    /// A straight line through 1 s a frame at 480p and 1.95 s at 720p (portrait, turned), encoding included. A quiet
    /// Mac did a 480p frame in 0.49–0.76 s and one busy with other work in up to 0.96 s, so a run seldom takes longer.
    public static func upscaleVideo(duration: TimeInterval, frameRate: Double, pixelSize: PixelSize) -> TimeInterval {
        let perFrame = 0.2389 + 1.8566e-6 * Double(pixelSize.width * pixelSize.height)
        return engineStart + max(duration, 0) * max(frameRate, 1) * perFrame
    }

    /// One picture, at the video line's cost of a frame.
    public static func upscaleImage(pixelSize: PixelSize) -> TimeInterval {
        upscaleVideo(duration: 1, frameRate: 1, pixelSize: pixelSize)
    }
}

/// How far an on-device run is.
public enum OnDeviceProgress: Sendable, Hashable {
    /// 0…1 of the engine's model, downloaded before its first run.
    case downloadingModel(Double)
    /// 0…1 of the frames.
    case working(Double)
}

/// The file an on-device run wrote.
public struct OnDeviceOutput: Sendable, Hashable {
    /// Upright, as the file shows.
    public var pixelSize: PixelSize
    /// In seconds.
    public var duration: TimeInterval
    /// The file's type as its extension: "mp4", "png".
    public var fileExtension: String

    public init(pixelSize: PixelSize, duration: TimeInterval, fileExtension: String) {
        self.pixelSize = pixelSize
        self.duration = duration
        self.fileExtension = fileExtension
    }

    public var outputMedia: OutputMedia { OutputMedia(duration: duration, pixelSize: pixelSize) }
}
