import AVFoundation
import CoreMedia
import Foundation
import JutsuCore
import Testing

@testable import MediaKit

/// The color tags an on-device result is written with: AVAssetWriterInput raises an exception nothing catches on a
/// tag its codec doesn't take, so only those it takes pass, and BT.709 stands in for the rest.
@Suite struct ColorTagsTests {
    @Test func tagsTheCodecDoesntTakeBecome709() {
        let odd = ColorTags(
            primaries: kCMFormatDescriptionColorPrimaries_P22 as String,
            transfer: kCMFormatDescriptionTransferFunction_UseGamma as String,
            matrix: "P3_D65")
        let bt709 = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        #expect(odd.writable(for: .h264) == bt709)
        #expect(odd.writable(for: .hevc) == bt709)
        #expect(ColorTags().writable(for: .h264) == bt709)
    }

    @Test func hevcKeepsWideGamutAndHDRAndH264DoesNot() {
        let hdr = ColorTags(
            primaries: AVVideoColorPrimaries_ITU_R_2020, transfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
            matrix: AVVideoYCbCrMatrix_ITU_R_2020)
        #expect(hdr.isHDR)
        #expect(hdr.writable(for: .hevc)[AVVideoTransferFunctionKey] == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        #expect(hdr.writable(for: .hevc)[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_2020)
        #expect(hdr.writable(for: .h264)[AVVideoTransferFunctionKey] == AVVideoTransferFunction_ITU_R_709_2)
        let p3 = ColorTags(primaries: AVVideoColorPrimaries_P3_D65)
        #expect(p3.writable(for: .hevc)[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_P3_D65)
        #expect(p3.writable(for: .h264)[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(!p3.isHDR)
    }

    /// The whole pipeline over a clip whose tags would have stopped the app: it writes, tagged BT.709.
    @Test func aClipTaggedWithGammaAndAP3MatrixIsWritten() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Fixtures.makeVideo(in: folder, width: 64, height: 36, seconds: 1, frameRate: 5)
        let loaded = try await FrameSource.load(clip)
        let source = FrameSource(
            asset: loaded.asset, video: loaded.video, audio: nil, naturalSize: loaded.naturalSize,
            transform: loaded.transform, frameRate: loaded.frameRate, duration: loaded.duration, isH264: true,
            isTenBit: false, isHDR: false,
            colorTags: ColorTags(
                primaries: kCMFormatDescriptionColorPrimaries_P22 as String,
                transfer: kCMFormatDescriptionTransferFunction_UseGamma as String,
                matrix: "P3_D65"))
        let output = folder.appending(path: "tagged.mp4")

        let pipeline = try await FramePipeline(
            source, to: output, pixelFormat: kCVPixelFormatType_32BGRA, size: source.naturalSize,
            frameRate: source.frameRate, keepsAudio: false)
        try pipeline.start()
        while let frame = try pipeline.nextFrame() { try await pipeline.append(frame) }
        try await pipeline.finish()

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        #expect(
            extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
                == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
    }
}
