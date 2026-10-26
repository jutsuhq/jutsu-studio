import Foundation

/// What an on-device Enhance run makes from the item it was started on (`OnDeviceEnhancing`).
public enum OnDeviceAction: Sendable, Hashable {
    case smoothMotion(SmoothMotion)

    /// The engine the action runs on.
    public var engine: OnDeviceEngine {
        switch self {
        case .smoothMotion: .frameRateConversion
        }
    }

    /// What the result's file name adds to the source's: "rooftop 60fps.mp4", "rooftop slow 2x.mp4".
    public var fileSuffix: String {
        switch self {
        case .smoothMotion(.fps60): "60fps"
        case .smoothMotion(.slowMotion2x): "slow 2x"
        case .smoothMotion(.slowMotion4x): "slow 4x"
        }
    }
}

/// VideoToolbox's frame processors, which on-device Enhance runs on.
public enum OnDeviceEngine: String, CaseIterable, Sendable, Hashable {
    /// Makes frames between a clip's own (Smooth Motion).
    case frameRateConversion
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
}

/// How far an on-device run is.
public enum OnDeviceProgress: Sendable, Hashable {
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
