import Foundation
import HiggsfieldMCP

/// `structuredContent` of `show_generations` with `{"size": 5}`, recorded on 2026-10-14. IDs, paths and long
/// prompts are placeholders, and the page is cut to its first item.
public enum RecordedGenerations {
    public static let structuredContent = #"""
        {
          "items": [
            {
              "id": "<job id>",
              "type": "video",
              "status": "completed",
              "model": "hf_mult_replace_object",
              "createdAt": 1791032606.742653,
              "liked": false,
              "params": {
                "prompt": "<1712 characters>",
                "enhanced_prompt": "<3251 characters>",
                "resolution": "720p",
                "aspect_ratio": "auto",
                "width": 1080,
                "height": 1920,
                "duration": 8,
                "batch_size": 1,
                "generate_audio": false,
                "medias": [
                  {"role": "video", "data": {"id": "<media id>", "type": "video_input", "url": "https://d2ol7oe51mr4n9.cloudfront.net/<path>"}},
                  {"role": "image", "data": {"id": "<media id>", "type": "media_input", "url": "https://d2ol7oe51mr4n9.cloudfront.net/<path>"}},
                  {"role": "image", "data": {"id": "<media id>", "type": "media_input", "url": "https://d2ol7oe51mr4n9.cloudfront.net/<path>"}},
                  {"role": "image", "data": {"id": "<media id>", "type": "media_input", "url": "https://d2ol7oe51mr4n9.cloudfront.net/<path>"}}
                ]
              },
              "results": {"rawUrl": "https://d8j0ntlcm91z4.cloudfront.net/<user id>/hf_<yyyyMMdd>_<HHmmss>_<job id>.mp4"}
            }
          ],
          "next_cursor": "<cursor; value not recorded>"
        }
        """#

    public static func value() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(structuredContent.utf8))
    }
}
