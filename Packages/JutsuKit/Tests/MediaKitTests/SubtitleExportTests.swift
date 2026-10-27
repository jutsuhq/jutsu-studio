import AVFoundation
import CoreGraphics
import Foundation
import JutsuCore
import Testing

@testable import MediaKit

/// Subtitles in real exports: burned into the frames, or written next to the video, timed as it is.
@Suite struct SubtitleExportTests {
    private let cues = [
        SubtitleCue(start: 0, end: 1, text: "HELLO THERE"),
        SubtitleCue(start: 1.2, end: 1.8, text: "Second line"),
    ]

    private func task(_ output: DeliveryOutput, fileName: String) -> DeliveryTask {
        let item = DeliverySet.Item(
            reference: MaterialReference(materialID: UUID(), versionID: UUID()), kind: .video, name: "item")
        return DeliveryTask(item: item, output: output, fileName: fileName, frame: nil, replacesExisting: false)
    }

    /// How many pixels of the frame at `seconds` are near white inside `rect` (from the top left).
    private func brightPixels(_ url: URL, at seconds: Double, in rect: CGRect) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = (y * width + x) * 4
                if bytes[offset] > 235, bytes[offset + 1] > 235, bytes[offset + 2] > 235 { count += 1 }
            }
        }
        return count
    }

    /// Two seconds of opaque dark grey frames at 640×360 without color tags, as some imported videos are.
    private func untaggedVideo(in directory: URL) async throws -> URL {
        let url = directory.appending(path: "\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let bytes = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) = (40, 40, 40, 255)
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 5))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func burnedInCuesShowInTheBottomOfTheFrameOnlyDuringTheirTime() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Untagged: Core Animation would render its frames white without the composition's color tags.
        let source = try await untaggedVideo(in: directory)
        let output = DeliveryOutput(preset: .video(.editingH264), subtitles: .burnIn)

        let file = try await DeliveryExporter.export(
            task(output, fileName: "burned.mp4"), source: source, subtitles: cues, into: directory
        ) { _ in }

        let plain = try await DeliveryExporter.export(
            task(DeliveryOutput(preset: .video(.editingH264)), fileName: "plain.mp4"), source: source, into: directory
        ) { _ in }
        let bottom = CGRect(x: 0, y: 240, width: 640, height: 120)
        let top = CGRect(x: 0, y: 0, width: 640, height: 120)
        #expect(try await brightPixels(file, at: 0.5, in: bottom) > 100)
        #expect(try await brightPixels(file, at: 0.5, in: top) == 0)
        #expect(try await brightPixels(file, at: 1.1, in: bottom) == 0)
        let duration = try await AVURLAsset(url: file).load(.duration).seconds
        #expect(abs(duration - 2) < 0.25)

        let square = DeliveryOutput(
            preset: .video(.editingH264), aspect: CropAspect(width: 1, height: 1), subtitles: .burnIn)
        let cropped = try await DeliveryExporter.export(
            task(square, fileName: "square.mp4"), source: source, subtitles: cues, into: directory
        ) { _ in }
        #expect(try await brightPixels(cropped, at: 0.5, in: CGRect(x: 0, y: 240, width: 360, height: 120)) > 100)
        #expect(try await brightPixels(cropped, at: 0.5, in: CGRect(x: 0, y: 0, width: 360, height: 120)) == 0)
    }

    @Test func subtitleFilesGoNextToTheVideoUnderItsName() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Fixtures.makeVideo(in: directory, width: 320, height: 180, seconds: 2)
        let output = DeliveryOutput(preset: .video(.editingH264), subtitles: .files)

        try await DeliveryExporter.export(
            task(output, fileName: "set_01_item.mp4"), source: source, subtitles: cues, into: directory
        ) { _ in }

        let srt = try String(contentsOf: directory.appending(path: "set_01_item.srt"), encoding: .utf8)
        let vtt = try String(contentsOf: directory.appending(path: "set_01_item.vtt"), encoding: .utf8)
        #expect(srt == SubtitleFormat.srt.text(of: cues))
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHELLO THERE\n"))
    }

    @Test func aTakenSubtitleNameLeavesTheFolderAsItWas() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Fixtures.makeVideo(in: directory, width: 320, height: 180, seconds: 1)
        try Data("theirs".utf8).write(to: directory.appending(path: "set_01_item.vtt"))
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let output = DeliveryOutput(preset: .video(.editingH264), subtitles: .files)

        await #expect(throws: (any Error).self) {
            try await DeliveryExporter.export(
                task(output, fileName: "set_01_item.mp4"), source: source, subtitles: cues, into: directory
            ) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
        #expect(try String(contentsOf: directory.appending(path: "set_01_item.vtt"), encoding: .utf8) == "theirs")
    }

    @Test func aFailedMoveTakesBackWhatItAdded() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: ".a.partial.mp4")
        try Data("video".utf8).write(to: video)
        let staged = [
            (staging: video, target: directory.appending(path: "take.mp4")),
            (staging: directory.appending(path: ".gone.partial.srt"), target: directory.appending(path: "take.srt")),
        ]

        #expect(throws: (any Error).self) { try DeliveryExporter.moveIn(staged, replacing: false) }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "take.mp4").path))
    }

    @Test func anOutputWithSubtitlesNeedsThem() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Fixtures.makeVideo(in: directory, width: 320, height: 180, seconds: 1)
        let output = DeliveryOutput(preset: .video(.editingH264), subtitles: .burnIn)

        await #expect(throws: DeliverySetError.noSubtitles) {
            try await DeliveryExporter.export(task(output, fileName: "none.mp4"), source: source, into: directory) {
                _ in
            }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "none.mp4").path))
    }

    @Test func textIsSizedToTheFrameAndFitsItsWidth() throws {
        #expect(SubtitleBurnIn.fontSize(for: CGSize(width: 1920, height: 1080)) == 49)
        #expect(SubtitleBurnIn.fontSize(for: CGSize(width: 1080, height: 1920)) == 42)
        let line = String(repeating: "W", count: 42)
        let picture = try #require(
            SubtitleBurnIn.picture(of: [line, "short"], frame: CGSize(width: 1080, height: 1920)))
        #expect(Double(picture.width) <= 1080 * 0.9 + 1)
        #expect(picture.height > 80)
        #expect(SubtitleBurnIn.picture(of: [], frame: CGSize(width: 640, height: 360)) == nil)
    }
}
