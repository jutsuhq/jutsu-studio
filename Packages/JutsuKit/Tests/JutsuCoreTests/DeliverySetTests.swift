import Foundation
import Testing

@testable import JutsuCore

@Suite struct DeliverySetTests {
    private static let web = DeliveryOutput(
        name: "web", preset: .image(ImageExportPreset(format: .jpeg, longEdge: 2048)),
        aspect: CropAspect(width: 4, height: 5))
    private static let master = DeliveryOutput(name: "master", preset: .image(ImageExportPreset(format: .png)))
    private static let phone = DeliveryOutput(preset: .image(ImageExportPreset(format: .heic, longEdge: 1080)))
    private static let edit = DeliveryOutput(preset: .video(.editingH264), aspect: CropAspect(width: 9, height: 16))

    private func image(_ name: String) -> Material {
        Material(kind: .image, version: MaterialVersion(fileURL: URL(filePath: "/library/\(name).png")))
    }

    private func set(images count: Int, outputs: [DeliveryOutput] = [web, master, phone]) -> DeliverySet {
        let materials = (1...count).map { image(String(format: "shot%02d", $0)) }
        return DeliverySet(name: "Spring", items: DeliverySet.items(from: materials), outputs: outputs)
    }

    private func allDone(_ set: inout DeliverySet) {
        let tasks = DeliveryPlan.tasks(for: set, scope: .all) { _ in false }
        set.record(tasks.map { $0.result(.done) }, in: .init(url: URL(filePath: "/out")), at: Date())
    }

    // MARK: Naming

    @Test func twentyImagesInThreeFormatsGiveSixtyDistinctNames() {
        let tasks = DeliveryPlan.tasks(for: set(images: 20), scope: .all) { _ in false }

        #expect(tasks.count == 60)
        #expect(Set(tasks.map { $0.fileName.lowercased() }).count == 60)
        #expect(tasks[0].fileName == "Spring_01_shot01_web.jpg")
        #expect(tasks[1].fileName == "Spring_01_shot01_master.png")
        #expect(tasks[2].fileName == "Spring_01_shot01_heic-1080.heic")
        #expect(tasks[59].fileName == "Spring_20_shot20_heic-1080.heic")
    }

    @Test func positionsArePaddedToTheSetSize() {
        #expect(
            ExportNaming.deliveryBaseName(set: "S", position: 7, count: 120, item: "a", output: "web") == "S_007_a_web")
        #expect(
            ExportNaming.deliveryBaseName(set: "S", position: 7, count: 9, item: "a", output: "web") == "S_07_a_web")
    }

    @Test func repeatedOutputNamesAreNumbered() {
        let first = DeliveryOutput(name: "web", preset: .image(ImageExportPreset(format: .jpeg)))
        let second = DeliveryOutput(name: "Web", preset: .image(ImageExportPreset(format: .png)))
        let labels = ExportNaming.outputLabels([first, second])

        #expect(labels[first.id] == "web")
        #expect(labels[second.id] == "Web-2")
    }

    @Test func aTakenNameIsNeverReused() {
        let tasks = DeliveryPlan.tasks(for: set(images: 1, outputs: [Self.master]), scope: .all) {
            $0 == "Spring_01_shot01_master.png"
        }

        #expect(tasks.map(\.fileName) == ["Spring_01_shot01_master-2.png"])
        #expect(tasks.map(\.replacesExisting) == [false])
    }

    @Test func aFileTheSetWroteIsWrittenAgainUnderItsName() {
        var delivery = set(images: 1, outputs: [Self.master])
        allDone(&delivery)

        let again = DeliveryPlan.tasks(for: delivery, scope: .all) { _ in true }

        #expect(again.map(\.fileName) == ["Spring_01_shot01_master.png"])
        #expect(again.map(\.replacesExisting) == [true])
    }

    @Test func imageOutputsTakeImagesAndVideoOutputsVideos() {
        let video = Material(kind: .video, version: MaterialVersion(fileURL: URL(filePath: "/library/clip.mp4")))
        let delivery = DeliverySet(
            name: "Mixed", items: DeliverySet.items(from: [image("still"), video]), outputs: [Self.master, Self.edit])

        let tasks = DeliveryPlan.tasks(for: delivery, scope: .all) { _ in false }

        #expect(tasks.map(\.fileName) == ["Mixed_01_still_master.png", "Mixed_02_clip_editingH264-9x16.mp4"])
    }

    // MARK: Crop

    @Test func theDefaultCropIsTheLargestCentredFrame() {
        let square = PixelSize(width: 1000, height: 1000)

        #expect(
            CropFrame.centered.rect(for: CropAspect(width: 4, height: 5), in: square)
                == PixelRect(x: 100, y: 0, width: 800, height: 1000))
        #expect(
            CropFrame.centered.rect(for: CropAspect(width: 16, height: 9), in: PixelSize(width: 1600, height: 1600))
                == PixelRect(x: 0, y: 350, width: 1600, height: 900))
    }

    @Test func aMovedOrZoomedCropStaysInsideThePicture() {
        let size = PixelSize(width: 1000, height: 1000)
        let aspect = CropAspect(width: 4, height: 5)

        #expect(CropFrame(centerX: 0).rect(for: aspect, in: size) == PixelRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(CropFrame(centerX: 1).rect(for: aspect, in: size) == PixelRect(x: 200, y: 0, width: 800, height: 1000))
        #expect(
            CropFrame(zoom: 2, centerX: 1, centerY: 1).rect(for: aspect, in: size)
                == PixelRect(x: 600, y: 500, width: 400, height: 500))
    }

    @Test func fixingOneCropMakesOnlyThatItemsCroppedFilesPending() {
        var delivery = set(images: 20)
        allDone(&delivery)
        #expect(DeliveryPlan.tasks(for: delivery, scope: .pending) { _ in true }.isEmpty)
        let fixed = delivery.items[4]

        delivery.setFrame(CropFrame(centerY: 0.2), for: fixed.reference, aspect: CropAspect(width: 4, height: 5))
        let pending = DeliveryPlan.tasks(for: delivery, scope: .pending) { _ in true }

        #expect(pending.map(\.item.reference) == [fixed.reference])
        #expect(pending.map(\.output.id) == [Self.web.id])
        #expect(pending.map(\.replacesExisting) == [true])
        #expect(pending.first?.frame == CropFrame(centerY: 0.2))
    }

    @Test func changingAnOutputMakesItsFilesPending() {
        var delivery = set(images: 2)
        allDone(&delivery)

        delivery.outputs[1].preset = .image(ImageExportPreset(format: .png, longEdge: 512))

        #expect(DeliveryPlan.tasks(for: delivery, scope: .pending) { _ in true }.count == 2)
    }

    // MARK: Freezing

    @Test func anExportedSetKeepsItsVersions() {
        var delivery = set(images: 2)
        allDone(&delivery)

        #expect(delivery.isFrozen)
        #expect(throws: DeliverySetError.frozen) { try delivery.setItems([]) }
        #expect(delivery.items.count == 2)
    }

    @Test func aRunWithNothingWrittenDoesntFreezeTheSet() {
        var delivery = set(images: 1, outputs: [Self.master])
        let tasks = DeliveryPlan.tasks(for: delivery, scope: .all) { _ in false }

        delivery.record(
            tasks.map { $0.result(.failed, message: "disk full") }, in: .init(url: URL(filePath: "/out")), at: Date())

        #expect(!delivery.isFrozen)
        #expect(delivery.status == .notExported)
        #expect(DeliveryPlan.tasks(for: delivery, scope: .failed) { _ in false }.count == 1)
    }

    @Test func theNextRoundTakesTheNewestVersionsAndStartsUnexported() throws {
        var first = image("hero")
        var delivery = DeliverySet(name: "Round 1", items: DeliverySet.items(from: [first]))
        allDone(&delivery)
        let held = delivery.items[0].reference
        try first.addVersion(MaterialVersion(fileURL: URL(filePath: "/library/hero edited.png")))

        let next = delivery.nextRound(name: "Round 2") { $0 == first.id ? first.reference : nil }

        #expect(delivery.items[0].reference == held)
        #expect(next.items[0].reference == first.reference)
        #expect(next.items[0].reference != held)
        #expect(!next.isFrozen)
        #expect(next.results.isEmpty)
        #expect(next.outputs == delivery.outputs)
    }

    @Test func aSetDecodesBackWithItsResults() throws {
        var delivery = set(images: 1)
        allDone(&delivery)
        delivery.note = "Second pass"
        delivery.reviewLink = "https://review.example/abc"

        let decoded = try JSONDecoder().decode(DeliverySet.self, from: JSONEncoder().encode(delivery))

        #expect(decoded == delivery)
    }

    @Test func theManifestListsEveryFileWithItsVersion() throws {
        var delivery = set(images: 2, outputs: [Self.master])
        allDone(&delivery)

        let manifest = ExportSidecar.Delivery(set: delivery, exportedAt: Date())
        let json = try #require(String(data: manifest.encoded(), encoding: .utf8))

        #expect(manifest.files.map(\.fileName) == ["Spring_01_shot01_master.png", "Spring_02_shot02_master.png"])
        #expect(manifest.files.map(\.versionID) == delivery.items.map(\.reference.versionID))
        #expect(!json.contains("/library"))
    }
}
