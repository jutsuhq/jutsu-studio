import Foundation
import HiggsfieldAPI

/// Response bodies as documented at docs.higgsfield.ai.
enum Fixture {
    static let presetID = UUID(uuidString: "c2143317-f28d-4c3c-a0b8-39bd547e08a7")!

    static let submitted = """
        {
          "status": "queued",
          "request_id": "req-123",
          "status_url": "https://api.higgsfield.ai/requests/req-123/status",
          "cancel_url": "https://api.higgsfield.ai/requests/req-123/cancel"
        }
        """

    static let presets = """
        {
          "model": "higgsfield/genjutsu/restyle/v1.0",
          "items": [
            {
              "id": "c2143317-f28d-4c3c-a0b8-39bd547e08a7",
              "name": "Cel-Shaded CG Anime",
              "preview_url": "https://cdn.higgsfield.ai/restyle_presets/259d7ddb-4201-49f7-8a91-cee5bce28715.webp"
            }
          ]
        }
        """

    /// Seedance `reference-to-video` without any reference array. The schema's rule ("Provide at least one nonempty
    /// reference array") is documented; the exact wording and `loc` of the 422 are assumed.
    static let seedanceWithoutReferences = """
        {"detail": [{"type": "value_error", "loc": ["body"],
          "msg": "Provide at least one nonempty reference array: image_urls, video_urls or audio_urls"}]}
        """

    static func status(_ status: String, extra: String = "") -> String {
        #"{"status": "\#(status)", "request_id": "req-123"\#(extra)}"#
    }

    static let videoURL = URL(string: "https://cdn.example.com/in.mp4")!
    static let imageURLs = [
        URL(string: "https://cdn.example.com/a.jpg")!, URL(string: "https://cdn.example.com/b.png")!,
    ]

    static func request(prompt: String = "", resolution: String = "480p", presetID: UUID? = nil) -> GenerationRequest {
        GenerationRequest(
            videoURL: videoURL, imageURLs: imageURLs, prompt: prompt, resolution: resolution, presetID: presetID)
    }
}
