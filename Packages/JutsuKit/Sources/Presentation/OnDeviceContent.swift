import Foundation
import JutsuCore

/// The texts of Enhance's runs on this Mac (`OnDeviceRuns`).
public enum OnDeviceText {
    public static let price = String(localized: "Free · runs on this Mac", bundle: .module)
    public static let versionNote = String(
        localized: "The result is added as a new version of this item; the version it is made from stays as it is.",
        bundle: .module)
    public static let smoothMotionNote = String(
        localized: "New frames are made between the clip's own. Across a cut a frame is repeated instead.",
        bundle: .module)
    public static let slowMotionSound = String(localized: "Slow motion plays without sound.", bundle: .module)
    public static let waiting = String(localized: "Waiting for the run before it", bundle: .module)
    public static let downloadingModel = String(localized: "Downloading the model", bundle: .module)
    public static let upscaleTitle = String(localized: "Upscale on This Mac", bundle: .module)
    public static let upscaleSound = String(localized: "The sound is kept as it is.", bundle: .module)
    /// Before the first run of an engine with a model (`OnDeviceModelConsent`).
    public static let modelNotice = String(
        localized:
            "Upscaling on this Mac needs a model macOS downloads from Apple once, about 62 MB. It is downloaded when the first upscale starts, and stays for later ones.",
        bundle: .module)
    public static let modelConsent = String(localized: "Download the model", bundle: .module)
    public static let tooLargeVideo = String(
        localized: "Upscale on this Mac takes videos up to 720p.", bundle: .module)
    public static let opaqueResult = String(
        localized: "This image has transparency; the upscaled image comes out opaque.", bundle: .module)
    public static let tooLargeImage = String(
        localized: "Upscale on this Mac takes images up to 1920×1080.", bundle: .module)

    /// "4× · 854×480 → 3416×1920".
    public static func upscaleSizes(_ source: PixelSize) -> String {
        let scale = OnDeviceUpscale.scale
        let output = PixelSize(width: source.width * scale, height: source.height * scale)
        return "\(scale)× · \(source.width)×\(source.height) → \(output.width)×\(output.height)"
    }

    /// "Takes ~2 min on this Mac".
    public static func expectedTime(_ seconds: TimeInterval) -> String {
        String(localized: "Takes \(JobRowModel.approximate(seconds)) on this Mac", bundle: .module)
    }

    /// "Smooth Motion · 42%", or that it waits.
    public static func progress(of run: OnDeviceRuns.Run) -> String {
        switch run.state {
        case .waiting: "\(run.request.action.title) · \(waiting)"
        case .downloadingModel(let fraction): "\(downloadingModel) · \(CostText.percent(fraction: fraction))"
        case .working(let fraction): "\(run.request.action.title) · \(CostText.percent(fraction: fraction))"
        }
    }

    /// Why Enhance's runs on this Mac are off for an item while one waits or runs on it: "Wait until Upscale 4×
    /// finishes".
    public static func busy(_ run: OnDeviceRuns.Run) -> String {
        String(localized: "Wait until \(run.request.action.title) finishes", bundle: .module)
    }

    /// The Enhance menu's hint when only this Mac's runs are on offer.
    public static func menuHint(_ offer: OnDeviceOffer) -> String {
        offer.upscaleVideo
            ? String(localized: "Smooth Motion and Upscale, free on this Mac", bundle: .module)
            : String(localized: "Smooth Motion, free on this Mac", bundle: .module)
    }

    public static func failureTitle(_ action: OnDeviceAction) -> String {
        String(localized: "Can't finish \(action.title)", bundle: .module)
    }
}

extension SmoothMotion {
    public var title: String {
        switch self {
        case .fps60: String(localized: "60 fps", bundle: .module)
        case .slowMotion2x: String(localized: "2× Slow Motion", bundle: .module)
        case .slowMotion4x: String(localized: "4× Slow Motion", bundle: .module)
        }
    }
}

extension OnDeviceAction {
    /// "Smooth Motion to 60 fps", "2× Slow Motion".
    public var title: String {
        switch self {
        case .smoothMotion(.fps60): String(localized: "Smooth Motion to 60 fps", bundle: .module)
        case .smoothMotion(let motion): motion.title
        case .upscaleVideo, .upscaleImage: String(localized: "Upscale 4×", bundle: .module)
        }
    }
}

/// Which of Enhance's runs on this Mac a result's page offers: only for a result with its file here, and only those
/// this Mac's engines can run.
public struct OnDeviceOffer: Sendable, Hashable {
    public var smoothMotion = false
    /// Only for a result up to 720p (`OnDeviceUpscale.offersVideo`).
    public var upscaleVideo = false

    public static let none = OnDeviceOffer()

    public var isEmpty: Bool { self == .none }

    /// - Parameter supports: whether this Mac has the engine (`OnDeviceRuns.supports`).
    public static func of(_ item: LibraryItemModel, supports: (OnDeviceEngine) -> Bool) -> OnDeviceOffer {
        guard item.outputFile != nil, !item.needsImport else { return .none }
        var offer = OnDeviceOffer()
        offer.smoothMotion = supports(.frameRateConversion)
        offer.upscaleVideo =
            supports(.videoSuperResolution) && item.job.outputPixelSize.map(OnDeviceUpscale.offersVideo) == true
        return offer
    }

    /// Whether a saved image of `size` (upright, `nil` when unread) is offered Upscale › On this Mac.
    public static func upscalesImage(_ size: PixelSize?, supports: (OnDeviceEngine) -> Bool) -> Bool {
        supports(.imageSuperResolution) && size.map(OnDeviceUpscale.offersImage) == true
    }
}

/// The person's agreement to macOS downloading an engine's model (`OnDeviceEngine.downloadsModel`), asked once per
/// engine before its first run and remembered.
public struct OnDeviceModelConsent {
    let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether a run on `engine` may start: one without a model always may.
    public func allows(_ engine: OnDeviceEngine) -> Bool {
        !engine.downloadsModel || defaults.bool(forKey: Self.key(engine))
    }

    public func agree(to engine: OnDeviceEngine) {
        defaults.set(true, forKey: Self.key(engine))
    }

    static func key(_ engine: OnDeviceEngine) -> String {
        "onDevice.modelConsent.\(engine.rawValue)"
    }
}
