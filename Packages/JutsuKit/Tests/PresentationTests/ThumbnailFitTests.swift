import Testing

@testable import Presentation

struct ThumbnailFitTests {
    private let tile = 16.0 / 9

    @Test(arguments: [(1920, 1080), (1280, 720), (1920, 1200), (854, 480)])
    func framesCloseToTheTileFillIt(width: Int, height: Int) {
        #expect(ThumbnailFit(width: width, height: height, tileAspect: tile) == .fill)
    }

    @Test(arguments: [(1080, 1920), (720, 1280), (1080, 1080), (1440, 1080), (2560, 1080)])
    func otherShapesAreFittedWhole(width: Int, height: Int) {
        #expect(ThumbnailFit(width: width, height: height, tileAspect: tile) == .fitOverBackdrop)
    }

    @Test(arguments: [(0, 0), (1920, 0), (0, 1080)])
    func framesWithoutASizeFill(width: Int, height: Int) {
        #expect(ThumbnailFit(width: width, height: height, tileAspect: tile) == .fill)
    }
}
