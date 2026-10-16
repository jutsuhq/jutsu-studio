import Foundation
import JutsuCore

/// "Export short preview": the start of a result, small enough for a messenger to show inline.
public enum ShortPreview {
    public static let length: TimeInterval = 5
    /// 480p: the shorter side, in pixels.
    public static let shortSide = 480
    /// Decimal megabytes, as messengers count them.
    public static let byteLimit: Int64 = 2_000_000

    /// The first `length` seconds, or the whole clip when it is shorter; `nil` for a clip with no length.
    public static func timeRange(duration: TimeInterval) -> ClosedRange<TimeInterval>? {
        guard duration.isFinite, duration > 0 else { return nil }
        return 0...min(length, duration)
    }

    /// `source` scaled so its shorter side is 480, with even sides for H.264; a smaller source keeps its size.
    public static func renderSize(for source: PixelSize) -> PixelSize? {
        guard source.isValid else { return nil }
        let scale = min(1, Double(shortSide) / Double(min(source.width, source.height)))
        let even = { (side: Int) in max(2, Int((Double(side) * scale / 2).rounded()) * 2) }
        return PixelSize(width: even(source.width), height: even(source.height))
    }

    /// "result-preview.mp4" for "result.mov".
    public static func fileName(for output: URL) -> String {
        "\(output.deletingPathExtension().lastPathComponent)-preview.mp4"
    }
}
