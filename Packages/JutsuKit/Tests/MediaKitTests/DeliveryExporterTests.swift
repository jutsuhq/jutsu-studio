import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import JutsuCore
import Testing
import UniformTypeIdentifiers

@testable import MediaKit

/// Real ImageIO output in temporary folders.
@Suite struct DeliveryExporterTests {
    /// A PNG whose left half is opaque red and right half fully transparent.
    private func halfTransparentPNG(in directory: URL, width: Int = 400, height: Int = 200) throws -> URL {
        let url = directory.appending(path: "\(UUID().uuidString).png")
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The RGBA of the pixel at `x`, `y` (from the top left), drawn into sRGB.
    private func pixel(_ url: URL, x: Int, y: Int) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<offset + 4])
    }

    private func typeOf(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(CGImageSourceGetType) as String?
    }

    private func task(
        _ output: DeliveryOutput, fileName: String, frame: CropFrame? = nil, replaces: Bool = false
    ) -> DeliveryTask {
        let item = DeliverySet.Item(
            reference: MaterialReference(materialID: UUID(), versionID: UUID()), kind: output.kind, name: "item")
        return DeliveryTask(
            item: item, output: output, fileName: fileName, frame: frame ?? item.frame(for: output.aspect),
            replacesExisting: replaces)
    }

    @Test func pngKeepsAlphaAndIsScaledDownToItsLongEdge() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try halfTransparentPNG(in: directory)
        let output = DeliveryOutput(preset: .image(ImageExportPreset(format: .png, longEdge: 100)))

        let file = try await DeliveryExporter.export(
            task(output, fileName: "a.png"), source: source, into: directory
        ) { _ in }

        #expect(typeOf(file) == UTType.png.identifier)
        #expect(Fixtures.imageSize(at: file).map { [$0.width, $0.height] } == [100, 50])
        #expect(try pixel(file, x: 10, y: 25) == [255, 0, 0, 255])
        #expect(try pixel(file, x: 90, y: 25)[3] == 0)
    }

    @Test func jpegFlattensOntoItsBackground() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try halfTransparentPNG(in: directory)
        // Qualified: the macOS 26.6 SDK also has a C `RGBColor`.
        let background = JutsuCore.RGBColor(red: 0, green: 0, blue: 1)
        let output = DeliveryOutput(
            preset: .image(ImageExportPreset(format: .jpeg, quality: 1, background: background)))

        let file = try await DeliveryExporter.export(
            task(output, fileName: "a.jpg"), source: source, into: directory
        ) { _ in }

        #expect(typeOf(file) == UTType.jpeg.identifier)
        #expect(Fixtures.imageSize(at: file).map { [$0.width, $0.height] } == [400, 200])
        let transparent = try pixel(file, x: 350, y: 100)
        #expect(transparent[0] < 20 && transparent[1] < 20 && transparent[2] > 235 && transparent[3] == 255)
        let red = try pixel(file, x: 50, y: 100)
        #expect(red[0] > 235 && red[2] < 20)
    }

    @Test func heicIsWrittenWhereThisMacHasAnEncoder() async throws {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard types.contains(UTType.heic.identifier) else { return }
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try halfTransparentPNG(in: directory)
        let output = DeliveryOutput(
            preset: .image(ImageExportPreset(format: .heic, longEdge: 200, colorSpace: .displayP3)))

        let file = try await DeliveryExporter.export(
            task(output, fileName: "a.heic"), source: source, into: directory
        ) { _ in }

        #expect(typeOf(file) == UTType.heic.identifier)
        #expect(Fixtures.imageSize(at: file).map { [$0.width, $0.height] } == [200, 100])
    }

    @Test func eachItemIsCroppedToItsOwnFrame() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try halfTransparentPNG(in: directory)
        let output = DeliveryOutput(
            preset: .image(ImageExportPreset(format: .png)), aspect: CropAspect(width: 1, height: 1))

        let left = try await DeliveryExporter.export(
            task(output, fileName: "left.png", frame: CropFrame(centerX: 0)), source: source, into: directory
        ) { _ in }
        let right = try await DeliveryExporter.export(
            task(output, fileName: "right.png", frame: CropFrame(centerX: 1)), source: source, into: directory
        ) { _ in }

        #expect(Fixtures.imageSize(at: left).map { [$0.width, $0.height] } == [200, 200])
        #expect(try pixel(left, x: 190, y: 100) == [255, 0, 0, 255])
        #expect(try pixel(right, x: 10, y: 100)[3] == 0)
    }

    @Test func twentyImagesInThreeOutputsWriteSixtyFiles() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = directory.appending(path: "sources")
        let delivered = directory.appending(path: "delivery")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: delivered, withIntermediateDirectories: true)
        var files: [UUID: URL] = [:]
        let materials = try (1...20).map { number -> Material in
            let file = sources.appending(path: String(format: "look%02d.png", number))
            try FileManager.default.moveItem(at: try halfTransparentPNG(in: sources, width: 60, height: 40), to: file)
            let material = Material(kind: .image, version: MaterialVersion(fileURL: file))
            files[material.current.id] = file
            return material
        }
        let delivery = DeliverySet(
            name: "Lookbook", items: DeliverySet.items(from: materials),
            outputs: [
                DeliveryOutput(name: "web", preset: .image(ImageExportPreset(format: .jpeg, longEdge: 32))),
                DeliveryOutput(name: "alpha", preset: .image(ImageExportPreset(format: .png))),
                DeliveryOutput(
                    name: "square", preset: .image(ImageExportPreset(format: .jpeg)),
                    aspect: CropAspect(width: 1, height: 1)),
            ])

        for task in DeliveryPlan.tasks(for: delivery, scope: .all, isTaken: { _ in false }) {
            let source = try #require(files[task.item.reference.versionID])
            try await DeliveryExporter.export(task, source: source, into: delivered) { _ in }
        }

        let written = try FileManager.default.contentsOfDirectory(atPath: delivered.path).sorted()
        #expect(written.count == 60)
        #expect(written.first == "Lookbook_01_look01_alpha.png")
        #expect(written.last == "Lookbook_20_look20_web.jpg")
        let square = delivered.appending(path: "Lookbook_07_look07_square.jpg")
        #expect(Fixtures.imageSize(at: square).map { [$0.width, $0.height] } == [40, 40])
    }

    @Test func onlyAFileTheSetWroteIsReplaced() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try halfTransparentPNG(in: directory)
        let output = DeliveryOutput(preset: .image(ImageExportPreset(format: .png, longEdge: 40)))
        let existing = directory.appending(path: "taken.png")
        try Data("someone else's".utf8).write(to: existing)

        await #expect(throws: (any Error).self) {
            try await DeliveryExporter.export(task(output, fileName: "taken.png"), source: source, into: directory) {
                _ in
            }
        }
        #expect(try Data(contentsOf: existing) == Data("someone else's".utf8))

        try await DeliveryExporter.export(
            task(output, fileName: "taken.png", replaces: true), source: source, into: directory
        ) { _ in }
        #expect(Fixtures.imageSize(at: existing).map { [$0.width, $0.height] } == [40, 20])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!leftovers.contains { $0.contains(".partial") })
    }

    @Test func anUnreadableSourceFailsAndLeavesNothing() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.png")
        try Data("not an image".utf8).write(to: broken)
        let output = DeliveryOutput(preset: .image(ImageExportPreset(format: .jpeg)))

        await #expect(throws: MediaError.unreadableImage) {
            try await DeliveryExporter.export(task(output, fileName: "out.jpg"), source: broken, into: directory) { _ in
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["broken.png"])
    }

    @Test func aVideoIsCroppedToItsOutputsAspect() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Fixtures.makeVideo(in: directory, seconds: 1)
        let output = DeliveryOutput(preset: .video(.editingH264), aspect: CropAspect(width: 1, height: 1))

        let file = try await DeliveryExporter.export(
            task(output, fileName: "clip.mp4", frame: CropFrame(centerX: 0)), source: source, into: directory
        ) { _ in }

        let track = try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let original = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
        let originalSize = try await original.load(.naturalSize)
        let side = min(originalSize.width, originalSize.height)
        #expect(size.width == side - side.truncatingRemainder(dividingBy: 2))
        #expect(size.width == size.height)
    }
}
