import Foundation

/// The shape a delivery output crops to, e.g. 4:5.
public struct CropAspect: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    /// "4x5": safe in a file name and as a dictionary key.
    public var key: String { "\(width)x\(height)" }
    /// "4:5".
    public var title: String { "\(width):\(height)" }
    public var ratio: Double { Double(width) / Double(height) }

    /// The shapes offered for an output.
    public static let common: [CropAspect] = [
        CropAspect(width: 1, height: 1), CropAspect(width: 4, height: 5), CropAspect(width: 3, height: 4),
        CropAspect(width: 2, height: 3), CropAspect(width: 9, height: 16), CropAspect(width: 16, height: 9),
        CropAspect(width: 3, height: 2), CropAspect(width: 4, height: 3),
    ]
}

/// Where an item's crop sits for one aspect, independent of the picture's pixel size: how far it is zoomed in from
/// the largest frame of that shape, and its centre as a fraction of the picture's width and height. The default is
/// the largest centred frame.
public struct CropFrame: Codable, Sendable, Hashable {
    /// 1 is the largest frame of the shape; 2 is half its width and height.
    public var zoom: Double
    /// 0…1 from the left.
    public var centerX: Double
    /// 0…1 from the top.
    public var centerY: Double

    public init(zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
    }

    public static let centered = CropFrame()
    public static let maximumZoom = 4.0

    /// The crop in a picture of `size`, upright, origin top left: never outside it and at least one pixel.
    public func rect(for aspect: CropAspect, in size: PixelSize) -> PixelRect {
        guard size.isValid else { return PixelRect(x: 0, y: 0, width: 0, height: 0) }
        let pictureWidth = Double(size.width)
        let pictureHeight = Double(size.height)
        var width = pictureWidth
        var height = pictureHeight
        if pictureWidth / pictureHeight > aspect.ratio {
            width = pictureHeight * aspect.ratio
        } else {
            height = pictureWidth / aspect.ratio
        }
        let scale = min(max(zoom.isFinite ? zoom : 1, 1), Self.maximumZoom)
        width = max(1, (width / scale).rounded())
        height = max(1, (height / scale).rounded())
        let x = Self.clamp(centerX * pictureWidth - width / 2, upTo: pictureWidth - width)
        let y = Self.clamp(centerY * pictureHeight - height / 2, upTo: pictureHeight - height)
        return PixelRect(x: Int(x.rounded()), y: Int(y.rounded()), width: Int(width), height: Int(height))
    }

    private static func clamp(_ value: Double, upTo limit: Double) -> Double {
        guard value.isFinite else { return max(0, limit / 2) }
        return min(max(value, 0), max(0, limit))
    }
}

/// A rectangle of whole pixels, origin top left.
public struct PixelRect: Codable, Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
}
