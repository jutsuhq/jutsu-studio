import Foundation

/// File names for editing exports, `<source>_<range>_<mode>_<style or refs>_v<N>.<ext>`, e.g.
/// `rooftop_00m04.0s-00m10.0s_restyle_Film Noir_v2.mov`. Takes of one shot sort together and in order.
public enum ExportNaming {
    public struct Names: Sendable, Hashable {
        public var video: String
        public var sidecar: String
    }

    static let maxSourceBytes = 120
    static let maxStyleBytes = 40
    /// Characters other file systems an editor's media may live on (exFAT, SMB) reject.
    static let unsafe: Set<Character> = ["\\", "*", "?", "\"", "<", ">", "|"]

    /// The first version whose video, under any preset's extension, and sidecar names are all free, so a
    /// new take never overwrites one and never shares a version number with an earlier take.
    public static func names(
        for spec: JobSpec, presetName: String?, preset: ExportPreset, isTaken: (String) -> Bool
    ) -> Names {
        let base = baseName(for: spec, presetName: presetName)
        let extensions = Set(ExportPreset.allCases.map(\.fileExtension)).sorted() + ["json"]
        var version = 1
        while extensions.contains(where: { isTaken("\(base)_v\(version).\($0)") }) {
            version += 1
        }
        let stem = "\(base)_v\(version)"
        return Names(video: "\(stem).\(preset.fileExtension)", sidecar: "\(stem).json")
    }

    /// The name before `_v<N>`.
    public static func baseName(for spec: JobSpec, presetName: String?) -> String {
        let source = field(spec.name, maxBytes: maxSourceBytes)
        let fields = [
            source.isEmpty ? "clip" : source,
            rangeText(spec.source?.range ?? 0...spec.duration),
            modeText(spec.mode),
            field(styleText(spec, presetName: presetName), maxBytes: maxStyleBytes),
        ]
        return fields.filter { !$0.isEmpty }.joined(separator: "_")
    }

    /// `00m04.0s-00m10.0s`: zero-padded so names sort by start time for ranges under 100 minutes.
    static func rangeText(_ range: ClosedRange<TimeInterval>) -> String {
        "\(timeText(range.lowerBound))-\(timeText(range.upperBound))"
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let tenths = seconds.isFinite ? max(0, Int((seconds * 10).rounded())) : 0
        return String(format: "%02ldm%02ld.%lds", tenths / 600, tenths % 600 / 10, tenths % 10)
    }

    static func modeText(_ mode: Mode) -> String {
        switch mode {
        case .motionTransfer: "motion"
        case .restyle: "restyle"
        case .objectSwap: "swap"
        case .edit: "edit"
        case .extend: "extend"
        }
    }

    /// The preset for restyle; otherwise the first reference image's name, `+N` for the others.
    private static func styleText(_ spec: JobSpec, presetName: String?) -> String {
        if spec.mode == .restyle {
            return presetName ?? (spec.presetID == nil ? "" : "preset")
        }
        guard let first = spec.references.first else { return "" }
        let name = first.fileURL.deletingPathExtension().lastPathComponent
        return spec.references.count > 1 ? "\(name)+\(spec.references.count - 1)" : name
    }

    // MARK: Delivery sets

    /// `<set>_<NN>_<item>_<output>`, e.g. `Spring launch_03_knight_web`: a set's files sort by item, then output.
    /// `NN` is the 1-based position, zero-padded to the width of `count` (at least two digits).
    public static func deliveryBaseName(set: String, position: Int, count: Int, item: String, output: String) -> String
    {
        let digits = max(2, String(max(count, 1)).count)
        let fields = [
            field(set, maxBytes: maxStyleBytes),
            String(repeating: "0", count: max(0, digits - String(position).count)) + String(position),
            field(item, maxBytes: maxStyleBytes),
            field(output, maxBytes: maxStyleBytes),
        ]
        return fields.filter { !$0.isEmpty }.joined(separator: "_")
    }

    /// The JSON written next to a delivery's files.
    public static func deliveryManifestName(set: String) -> String {
        let name = field(set, maxBytes: maxSourceBytes)
        return "\(name.isEmpty ? "delivery" : name)_manifest.json"
    }

    /// The file-name part of each output, in order: its name, else its summary; a repeat gets `-2`, `-3`…
    public static func outputLabels(_ outputs: [DeliveryOutput]) -> [UUID: String] {
        var used: Set<String> = []
        var labels: [UUID: String] = [:]
        for output in outputs {
            let base = field(output.name.isEmpty ? output.summary : output.name, maxBytes: maxStyleBytes)
            var label = base
            var number = 2
            while !used.insert(label.lowercased()).inserted {
                label = "\(base)-\(number)"
                number += 1
            }
            labels[output.id] = label
        }
        return labels
    }

    /// One name field, safe as part of a path component on macOS and the usual shared volumes.
    static func field(_ text: String, maxBytes: Int) -> String {
        var result = String(OutputNamePattern.sanitize(text).map { unsafe.contains($0) ? "-" : $0 })
        while result.utf8.count > maxBytes { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
