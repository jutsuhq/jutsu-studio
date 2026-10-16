import Foundation
import Testing

@testable import JutsuCore

@Suite struct ReferenceImageTests {
    @Test func aReferenceStoredBeforePromptsDecodes() throws {
        let stored = Data(#"{"fileURL":"file:///tmp/a.png"}"#.utf8)
        let image = try JSONDecoder().decode(LocalImage.self, from: stored)
        #expect(image == LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.png")))
        #expect(image.prompt == nil)
    }

    @Test func aTemplateKeepsTheGeneratedPrompt() throws {
        let image = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.png"), prompt: "a knight in silver armor")
        let template = JobTemplate(
            name: "Knight", mode: .motionTransfer, references: [image], prompt: "", resolution: .p720)

        let decoded = try JSONDecoder().decode(JobTemplate.self, from: JSONEncoder().encode(template))

        #expect(decoded.references.map(\.prompt) == ["a knight in silver armor"])
    }

    @Test(arguments: [
        (1920, 1080, "16:9"), (1080, 1920, "9:16"), (1000, 1000, "1:1"), (1440, 1080, "4:3"), (0, 0, "1:1"),
    ])
    func theNearestFrameIsPicked(width: Int, height: Int, expected: String) {
        let model = ImageModel(id: "m", title: "M", aspectRatios: ["1:1", "4:3", "16:9", "9:16"])
        #expect(model.nearestAspectRatio(width: width, height: height) == expected)
    }

    @Test func imageRequestsCountInTheirUnitOnTheirDayOrWhileRunning() {
        let calendar = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_760_310_000)
        let charges = [
            ImageCharge(
                date: day, cost: .usd(2, isEstimate: false), providerKind: .apiKey, model: "a", images: 1,
                isPending: false),
            ImageCharge(
                date: day - 3 * 86_400, cost: .usd(1, isEstimate: true), providerKind: .apiKey, model: "b", images: 1),
            ImageCharge(
                date: day - 3 * 86_400, cost: .usd(5, isEstimate: false), providerKind: .apiKey, model: "c", images: 1,
                isPending: false),
        ]
        #expect(Budget.committed(charges, on: day, in: .usd, calendar: calendar) == 3)
        #expect(Budget.committed(charges, on: day, in: .credits, calendar: calendar) == 0)
    }
}
