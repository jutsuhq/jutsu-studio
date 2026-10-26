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

    /// "Takes ~2 min on this Mac".
    public static func expectedTime(_ seconds: TimeInterval) -> String {
        String(localized: "Takes \(JobRowModel.approximate(seconds)) on this Mac", bundle: .module)
    }

    /// "Smooth Motion · 42%", or that it waits.
    public static func progress(of run: OnDeviceRuns.Run) -> String {
        switch run.state {
        case .waiting: "\(run.request.action.title) · \(waiting)"
        case .working(let fraction): "\(run.request.action.title) · \(CostText.percent(fraction: fraction))"
        }
    }

    /// Why Enhance's runs on this Mac are off for an item while one waits or runs on it: "Wait until Smooth Motion to
    /// 60 fps finishes".
    public static func busy(_ run: OnDeviceRuns.Run) -> String {
        String(localized: "Wait until \(run.request.action.title) finishes", bundle: .module)
    }

    /// The Enhance menu's hint when only this Mac's runs are on offer.
    public static func menuHint(_ offer: OnDeviceOffer) -> String {
        String(localized: "Smooth Motion, free on this Mac", bundle: .module)
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
        }
    }
}

/// Which of Enhance's runs on this Mac a result's page offers: only for a result with its file here, and only those
/// this Mac's engines can run.
public struct OnDeviceOffer: Sendable, Hashable {
    public var smoothMotion = false

    public static let none = OnDeviceOffer()

    public var isEmpty: Bool { self == .none }

    /// - Parameter supports: whether this Mac has the engine (`OnDeviceRuns.supports`).
    public static func of(_ item: LibraryItemModel, supports: (OnDeviceEngine) -> Bool) -> OnDeviceOffer {
        guard item.outputFile != nil, !item.needsImport else { return .none }
        var offer = OnDeviceOffer()
        offer.smoothMotion = supports(.frameRateConversion)
        return offer
    }
}
