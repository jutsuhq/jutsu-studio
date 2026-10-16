import Foundation

/// The frame of a clip made without a source video, as `generate_video` names it; a clip made from a source keeps
/// the source's frame.
public enum AspectRatio: String, Codable, Sendable, CaseIterable {
    /// The model's choice: the reference image's frame when there is one.
    case auto
    case cinema = "21:9"
    case landscape = "16:9"
    case classic = "4:3"
    case square = "1:1"
    case classicPortrait = "3:4"
    case portrait = "9:16"

    /// Width over height; `nil` for `auto`, whose frame only the result shows.
    public var widthOverHeight: Double? {
        let sides = rawValue.split(separator: ":").compactMap { Double($0) }
        guard sides.count == 2, sides[1] > 0 else { return nil }
        return sides[0] / sides[1]
    }

    /// The fixed frame closest in shape to `size` (never `auto`); `nil` for a size without both sides. A start
    /// frame's ratio, which the account's Seedance doesn't derive itself: sent none, it made a 16:9 clip from a 9:16
    /// start frame in a live run on 2026-10-15.
    public static func nearest(to size: PixelSize) -> AspectRatio? {
        guard size.isValid else { return nil }
        let target = log(Double(size.width) / Double(size.height))
        return allCases.compactMap { ratio in ratio.widthOverHeight.map { (ratio, abs(log($0) - target)) } }
            .min { $0.1 < $1.1 }?.0
    }
}
