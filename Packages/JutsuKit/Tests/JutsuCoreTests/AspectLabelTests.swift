import Testing

@testable import JutsuCore

struct AspectLabelTests {
    @Test(arguments: [
        (1920, 1080, "16:9"), (1460, 1100, "4:3"), (1456, 1092, "4:3"), (1024, 1024, "1:1"), (1536, 1024, "3:2"),
        (1080, 1350, "4:5"), (2048, 878, "21:9"), (1000, 300, "10:3"), (1001, 300, "21:9"),
    ])
    func aSizeGetsTheFramePeopleName(width: Int, height: Int, label: String) {
        #expect(PixelSize(width: width, height: height).aspectLabel == label)
    }

    @Test func aStoredRatioIsRelabelled() {
        #expect(PixelSize.aspectLabel(of: "73:55") == "4:3")
        #expect(PixelSize.aspectLabel(of: "16:9") == "16:9")
        #expect(PixelSize.aspectLabel(of: "auto") == "auto")
        #expect(PixelSize(width: 0, height: 10).aspectLabel == nil)
    }
}
