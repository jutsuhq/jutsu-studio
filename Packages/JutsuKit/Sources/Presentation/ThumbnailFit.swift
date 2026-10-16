/// How a frame sits in a tile of a fixed shape, such as the library grid's 16:9 cards.
public enum ThumbnailFit: Equatable, Sendable {
    /// Fills the tile; the little it crops isn't worth bars.
    case fill
    /// Shown whole, over a blurred copy of itself filling the rest of the tile.
    case fitOverBackdrop

    /// The widest a frame may be, or the narrowest, relative to the tile and still fill it: 16:10 in a 16:9 tile
    /// loses about 5% on each side, 4:3 would lose 12%.
    static let fillTolerance = 1.12

    /// A frame close to the tile's shape fills it; a portrait, square, 4:3 or ultra-wide frame is fitted so none
    /// of it is cut. A frame without a usable size fills, as every tile did before sizes were checked.
    public init(width: Int, height: Int, tileAspect: Double) {
        guard width > 0, height > 0, tileAspect > 0 else {
            self = .fill
            return
        }
        let relative = Double(width) / Double(height) / tileAspect
        self = (1 / Self.fillTolerance...Self.fillTolerance).contains(relative) ? .fill : .fitOverBackdrop
    }
}
