import Foundation

@testable import JutsuCore

func makeSpec(
    mode: Mode = .motionTransfer,
    duration: TimeInterval = 10,
    size: PixelSize = PixelSize(width: 1280, height: 720),
    allowsUpscale: Bool = false,
    references: Int = 1,
    presetID: UUID? = nil,
    prompt: String = "",
    resolution: Resolution = .p480
) -> JobSpec {
    let source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 60, pixelSize: size, range: 0...duration,
        allowsUpscale: allowsUpscale)
    let images = (0..<references).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref\($0).jpg")) }
    return JobSpec(
        mode: mode, source: source, references: images, presetID: presetID, prompt: prompt, resolution: resolution)
}
