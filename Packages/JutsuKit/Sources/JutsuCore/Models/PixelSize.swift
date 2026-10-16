import Foundation

public struct PixelSize: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Sides of at least one pixel; `Validation.check` rejects anything else.
    public var isValid: Bool { width > 0 && height > 0 }

    /// 0 for an invalid size, `Int.max` when the product doesn't fit in an `Int`.
    public var pixelCount: Int {
        guard isValid else { return 0 }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? .max : count
    }
}

extension PixelSize {
    /// Frames people name, landscape to portrait.
    static let namedRatios: [(name: String, value: Double)] = [
        ("21:9", 21 / 9), ("16:9", 16 / 9), ("3:2", 3 / 2), ("4:3", 4 / 3), ("5:4", 5 / 4), ("1:1", 1),
        ("4:5", 4 / 5), ("3:4", 3 / 4), ("2:3", 2 / 3), ("9:16", 9 / 16),
    ]

    /// The frame as people name it, "4:3"; `nil` for an invalid size. Models round their sides (1460×1100 is
    /// 73:55), so a size within 2 % of a named frame gets its name; another keeps its reduced ratio while both terms
    /// are at most 32, and otherwise gets the nearest named frame.
    public var aspectLabel: String? {
        guard isValid else { return nil }
        let shape = log(Double(width) / Double(height))
        let nearest = Self.namedRatios.min { abs(log($0.value) - shape) < abs(log($1.value) - shape) }
        guard let nearest else { return nil }
        if abs(log(nearest.value) - shape) < 0.02 { return nearest.name }
        var (a, b) = (width, height)
        while b != 0 { (a, b) = (b, a % b) }
        let (w, h) = (width / a, height / a)
        return max(w, h) <= 32 ? "\(w):\(h)" : nearest.name
    }

    /// `aspectLabel` for a stored "W:H"; any other text as it is.
    public static func aspectLabel(of ratio: String) -> String {
        let sides = ratio.split(separator: ":").compactMap { Int($0) }
        guard sides.count == 2 else { return ratio }
        return PixelSize(width: sides[0], height: sides[1]).aspectLabel ?? ratio
    }
}
