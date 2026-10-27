import Foundation

/// Subtitle files: SubRip (`.srt`) and WebVTT (`.vtt`), timed as the cues are, from the start of the video.
public enum SubtitleFormat: String, Codable, Sendable, CaseIterable {
    case srt
    case vtt

    public var fileExtension: String { rawValue }

    /// The file's text, UTF-8, with "\n" line ends. Cues without text are left out; an arrow in a cue's text is
    /// written as "→", as "-->" would end its timing line.
    public func text(of cues: [SubtitleCue]) -> String {
        let shown = cues.filter { !$0.lines.isEmpty }
        switch self {
        case .srt:
            return shown.enumerated().map { offset, cue in
                "\(offset + 1)\n\(Self.timestamp(cue.start, ",")) --> \(Self.timestamp(cue.end, ","))\n"
                    + Self.body(cue) + "\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n"
                + shown.map { cue in
                    "\(Self.timestamp(cue.start, ".")) --> \(Self.timestamp(cue.end, "."))\n" + Self.body(cue) + "\n"
                }.joined(separator: "\n")
        }
    }

    private static func body(_ cue: SubtitleCue) -> String {
        cue.lines.map { $0.replacingOccurrences(of: "-->", with: "→") }.joined(separator: "\n")
    }

    /// "00:01:02,345" for SRT, "00:01:02.345" for VTT; rounded to the millisecond.
    static func timestamp(_ seconds: TimeInterval, _ separator: String) -> String {
        let total = Int((max(seconds, 0) * 1000).rounded())
        let hours = total / 3_600_000
        let minutes = total / 60000 % 60
        let secs = total / 1000 % 60
        let millis = total % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis)
    }
}
