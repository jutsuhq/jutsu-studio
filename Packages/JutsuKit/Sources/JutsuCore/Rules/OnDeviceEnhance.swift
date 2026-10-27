import Foundation

/// What an on-device Enhance run makes from the item it was started on (`OnDeviceEnhancing`).
public enum OnDeviceAction: Sendable, Hashable {
    case smoothMotion(SmoothMotion)
    /// 4× the frame size of a clip up to 720p (`OnDeviceUpscale`).
    case upscaleVideo

    /// The engine the action runs on.
    public var engine: OnDeviceEngine {
        switch self {
        case .smoothMotion: .frameRateConversion
        case .upscaleVideo: .videoSuperResolution
        }
    }

    /// What the result's file name adds to the source's: "rooftop 60fps.mp4", "rooftop 4x.mp4".
    public var fileSuffix: String {
        switch self {
        case .smoothMotion(.fps60): "60fps"
        case .smoothMotion(.slowMotion2x): "slow 2x"
        case .smoothMotion(.slowMotion4x): "slow 4x"
        case .upscaleVideo: "4x"
        }
    }
}

/// VideoToolbox's frame processors, which on-device Enhance runs on.
public enum OnDeviceEngine: String, CaseIterable, Sendable, Hashable {
    /// Makes frames between a clip's own (Smooth Motion).
    case frameRateConversion
    /// Super resolution of the video kind, which uses the frames before to keep detail steady.
    case videoSuperResolution

    /// Whether the engine needs a model macOS downloads once (about 62 MB a kind) before its first run. Merely
    /// setting the engine up for a size starts that download, so it is done only once the person has agreed.
    public var downloadsModel: Bool {
        switch self {
        case .frameRateConversion: false
        case .videoSuperResolution: true
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

    /// Video sources up to 720p either way round: at 1080p the 4× frames ran a 16 GB Mac out of memory (#13).
    public static func offersVideo(_ size: PixelSize) -> Bool {
        size.isValid && max(size.width, size.height) <= 1280 && min(size.width, size.height) <= 720
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
    /// The file's type as its extension: "mp4".
    public var fileExtension: String

    public init(pixelSize: PixelSize, duration: TimeInterval, fileExtension: String) {
        self.pixelSize = pixelSize
        self.duration = duration
        self.fileExtension = fileExtension
    }

    public var outputMedia: OutputMedia { OutputMedia(duration: duration, pixelSize: pixelSize) }
}
