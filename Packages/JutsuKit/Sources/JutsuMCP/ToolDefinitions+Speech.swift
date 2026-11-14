import HiggsfieldMCP
import JutsuAgent

extension Tool {
    /// The speech of a model whose characters say a recording: `create_video` takes the file, a quote, which reads
    /// no file, its seconds.
    static func speechProperty(files: Bool) -> [String: JSONValue] {
        if files {
            return [
                "speech": [
                    "type": "string",
                    "description": .string(
                        "A speech recording on this Mac (MP3, WAV, M4A…), for a model whose takesSpeech is true "
                            + "(capabilities): the characters say it, and its length sets the clip's."),
                ]
            ]
        }
        return [
            "speech_length": [
                "type": "number", "exclusiveMinimum": 0, "maximum": .number(AgentVideoRequest.maxLength),
                "description": "Seconds the speech recording runs, for a model whose takesSpeech is true.",
            ]
        ]
    }
}
