import Foundation

/// How downloaded results are named, e.g. `{date}_{mode}_{id}` → `2026-03-07_restyle_1a2b3c4d.mp4`.
/// An empty pattern, or one with an unknown or unclosed token, means `defaultPattern`.
public struct OutputNamePattern: Sendable, Hashable {
    public enum Token: String, CaseIterable, Sendable {
        case date, time, mode, preset, res, draft, id

        public var placeholder: String { "{\(rawValue)}" }
    }

    public static let defaultPattern = "{date}_{mode}_{id}"
    public static let standard = OutputNamePattern(defaultPattern)
    public static let fileExtension = "mp4"
    /// UTF-8 bytes of the name before the counter and extension; macOS allows 255 per path component.
    static let maxBaseBytes = 200

    public let pattern: String

    public init(_ pattern: String) {
        self.pattern = Self.isValid(pattern) ? pattern : Self.defaultPattern
    }

    public static func isValid(_ pattern: String) -> Bool {
        !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parse(pattern) != nil
    }

    /// Characters an empty token must not leave doubled, or at either end of the name.
    static let separators: Set<Character> = ["_", "-", ".", " "]

    /// The sanitized name with its extension, dated in `timeZone`. `presetName` is `nil` when the
    /// catalog doesn't know the preset; a name that sanitizes to nothing falls back to the default.
    /// - Parameter fileExtension: `nil` for `Self.fileExtension`.
    public func fileName(
        for job: Job, presetName: String?, timeZone: TimeZone = .current, fileExtension: String? = nil
    ) -> String {
        var base = Self.base(expand(for: job, presetName: presetName, timeZone: timeZone))
        if base.isEmpty {
            base = Self.base(Self.standard.expand(for: job, presetName: presetName, timeZone: timeZone))
        }
        return "\(base).\(fileExtension ?? Self.fileExtension)"
    }

    /// The lowercased extension of a result's download URL, so an operation's result in another container keeps it
    /// (every one seen live was `.mp4`, a background cut-out included); `fileExtension` when the URL names none or a
    /// suspicious one.
    public static func resultExtension(of url: URL) -> String {
        let candidate = url.pathExtension.lowercased()
        let isPlain =
            (1...5).contains(candidate.count) && candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return isPlain ? candidate : fileExtension
    }

    private static func base(_ expanded: String) -> String {
        let sanitized = sanitize(expanded)
        let start = sanitized.firstIndex { !separators.contains($0) } ?? sanitized.endIndex
        let end = sanitized.lastIndex { !separators.contains($0) }.map { sanitized.index(after: $0) } ?? start
        return String(sanitized[start..<max(start, end)])
    }

    /// Safe as one path component: `/` and `:` become `-`, control characters, leading dots and
    /// surrounding spaces go, and the result is cut to `maxBaseBytes`.
    public static func sanitize(_ name: String) -> String {
        let scalars = name.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar == "/" || scalar == ":" { return "-" }
            return scalar.properties.generalCategory == .control ? nil : scalar
        }
        var result = Substring(String(String.UnicodeScalarView(scalars)))
        result = result.drop { $0 == "." || $0.isWhitespace }
        while result.utf8.count > maxBaseBytes { result = result.dropLast() }
        while result.last?.isWhitespace == true { result = result.dropLast() }
        return String(result)
    }

    /// `fileName` if `isTaken` rejects it, otherwise the first free `name-2.ext`, `name-3.ext`, …
    public static func available(_ fileName: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(fileName) else { return fileName }
        let dot = fileName.lastIndex(of: ".").flatMap { $0 == fileName.startIndex ? nil : $0 } ?? fileName.endIndex
        let stem = fileName[..<dot]
        let suffix = fileName[dot...]
        var counter = 2
        while isTaken("\(stem)-\(counter)\(suffix)") { counter += 1 }
        return "\(stem)-\(counter)\(suffix)"
    }

    private enum Part {
        case text(Substring)
        case token(Token)
    }

    private static func parse(_ pattern: String) -> [Part]? {
        var parts: [Part] = []
        var rest = pattern[...]
        while let open = rest.firstIndex(of: "{") {
            parts.append(.text(rest[..<open]))
            guard let close = rest[open...].firstIndex(of: "}"),
                let token = Token(rawValue: String(rest[rest.index(after: open)..<close]))
            else { return nil }
            parts.append(.token(token))
            rest = rest[rest.index(after: close)...]
        }
        parts.append(.text(rest))
        return parts
    }

    private func expand(for job: Job, presetName: String?, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        var result = ""
        var followsEmptyToken = false
        for part in Self.parse(pattern) ?? [] {
            switch part {
            case .text(var text):
                guard !text.isEmpty else { continue }
                if followsEmptyToken, let first = text.first, Self.separators.contains(first), result.last == first {
                    text = text.dropFirst()
                }
                result += text
                followsEmptyToken = false
            case .token(let token):
                let value = value(of: token, for: job, presetName: presetName, formatter: formatter)
                result += value
                followsEmptyToken = value.isEmpty
            }
        }
        return result
    }

    private func value(of token: Token, for job: Job, presetName: String?, formatter: DateFormatter) -> String {
        switch token {
        case .date:
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: job.createdAt)
        case .time:
            formatter.dateFormat = "HH-mm-ss"
            return formatter.string(from: job.createdAt)
        case .mode: return job.spec.mode.rawValue
        case .preset: return job.spec.presetID == nil ? "" : presetName ?? "preset"
        case .res: return job.spec.resolution.rawValue
        case .draft: return job.spec.isDraft ? "draft" : ""
        case .id: return job.id.uuidString.prefix(8).lowercased()
        }
    }
}
