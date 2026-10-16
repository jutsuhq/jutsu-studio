import Foundation
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// The catalog snapshot of 2026-10-15 as the client reads it: every role finds its tool by name and arguments, and
/// the schema check the other tests rely on catches what the server would refuse.
@Suite struct CatalogSnapshotTools {
    @Test func everyRoleFindsItsToolInTheSnapshot() throws {
        let tools = try ToolRole.allCases.map { role in
            try CatalogSnapshot.tool(role.rawValue).decode(MCPTool.self)
        }
        let catalog = ToolCatalog(tools)
        let missing = ToolRole.allCases.filter { catalog[$0] == nil }
        #expect(missing.isEmpty)
    }

    @Test func theSchemaCheckCatchesWhatTheServerRefuses() throws {
        // Topaz takes no frame rate, and a video is named by a UUID.
        let upscale: JSONValue = [
            "params": ["provider": "topaz", "video_id": "job-1", "resolution": "2160p", "fps": 30]
        ]
        #expect(try !CatalogSnapshot.violations(of: upscale, sentTo: "upscale_video").isEmpty)
        // The first guess of the Virality Predictor call.
        let virality: JSONValue = ["action": "create", "job_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"]
        #expect(try !CatalogSnapshot.violations(of: virality, sentTo: "virality_predictor").isEmpty)
        // A language outside the enum.
        let dub: JSONValue = [
            "params": ["video_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "target_language": "nld"]
        ]
        #expect(try !CatalogSnapshot.violations(of: dub, sentTo: "dubbing").isEmpty)
        let dubFrench: JSONValue = [
            "params": ["video_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "target_language": "fra"]
        ]
        #expect(try CatalogSnapshot.violations(of: dubFrench, sentTo: "dubbing").isEmpty)
    }

    /// The model schemas of `models_explore get`: roles, parameter names, options, ranges and types.
    @Test func theModelSchemaCheckCatchesWhatTheModelDoesntTake() throws {
        let kling = VideoRequest(
            model: VideoRequest.Model(rawValue: "kling_video_edit"),
            media: [.init(role: .video, id: "video-1"), .init(role: .image, id: "image-1")], prompt: "make it rain",
            mode: VideoRequest.klingPro)
        #expect(try CatalogSnapshot.violations(ofParams: kling.arguments()["params"] ?? .null).isEmpty)

        var wan = VideoRequest(
            model: VideoRequest.Model(rawValue: "wan2_7"), media: [.init(role: .video, id: "video-1")],
            resolution: "480p", duration: 30, generateAudio: true)
        wan.aspectRatio = "auto"
        let found = try CatalogSnapshot.violations(ofParams: wan.arguments()["params"] ?? .null)
        // Wan 2.7 takes no reference video, no "auto" frame, at most 15 s, no soundtrack switch and no 480p.
        let expected = [
            "wan2_7: role video_references", "wan2_7: aspect_ratio", "wan2_7.duration: above max",
            "wan2_7: generate_audio isn't a parameter", "wan2_7.resolution:",
        ]
        #expect(found.count == expected.count)
        for prefix in expected { #expect(found.contains { $0.hasPrefix(prefix) }, "\(prefix)") }
        #expect(throws: (any Error).self) {
            try CatalogSnapshot.violations(ofParams: ["model": "no_such_model"])
        }
    }
}
