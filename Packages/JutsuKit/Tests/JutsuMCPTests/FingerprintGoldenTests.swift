import Foundation
import HiggsfieldMCP
import JutsuAgent
import Testing

@testable import JutsuMCP

/// Requests an agent could send before several inputs and elements existed keep their exact fingerprints, so one
/// sent again after an update is the same request and is never paid twice. The values are what the release before
/// gave for the same arguments; the files don't exist, so no size goes in.
@Suite struct FingerprintGoldenTests {
    private let folder = URL(filePath: "/nonexistent-golden")

    @Test func aOneInputCreateImageKeepsItsFingerprint() throws {
        let arguments: [String: JSONValue] = [
            "request_id": "golden-1", "model": "gpt_image_2", "prompt": "the fox in a red coat",
            "aspect_ratio": "16:9", "count": 2, "input": "/nonexistent-golden/fox.png",
            "max_cost": ["amount": .number(2.509), "unit": "usd"],
        ]
        guard case .success(.createImage(let command)) = Tool.createImage.command(arguments, workingDirectory: folder)
        else {
            Issue.record("no create_image")
            return
        }
        #expect(command.fingerprint == "4bad0d4e5e60c968c6ebd36d1e74c3057c380373a78ce9ddc2d367ea437af102")
    }

    @Test func aCreateVideoWithoutElementsKeepsItsFingerprint() throws {
        let arguments: [String: JSONValue] = [
            "request_id": "golden-2", "mode": "motion_transfer", "model": "seedance25", "prompt": "she dances",
            "source": ["path": "/nonexistent-golden/clip.mov", "start": 1, "end": 6],
            "images": ["/nonexistent-golden/face.png"], "resolution": "720p", "draft": true, "audio": "original",
            "max_cost": ["amount": .number(2.509), "unit": "usd"],
        ]
        guard case .success(.createVideo(let command)) = Tool.createVideo.command(arguments, workingDirectory: folder)
        else {
            Issue.record("no create_video")
            return
        }
        #expect(command.fingerprint == "a0c4a0ea7b6a3c48a863ff962c5843c6dd3e7f34515b93b4e5859e993bdfd7d2")
    }
}
