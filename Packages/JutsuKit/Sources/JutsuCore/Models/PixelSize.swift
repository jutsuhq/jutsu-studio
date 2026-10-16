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
