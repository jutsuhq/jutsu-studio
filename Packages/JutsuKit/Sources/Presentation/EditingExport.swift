import Foundation
import JutsuCore

extension ExportPreset {
    public var title: String {
        switch self {
        case .premiere: "Premiere Pro"
        case .davinciResolve: "DaVinci Resolve"
        case .finalCutPro: "Final Cut Pro"
        case .editingH264: String(localized: "Editing H.264", bundle: .module)
        }
    }

    /// "ProRes 422 · PCM · MOV", under the title in the export menu.
    public var formatSummary: String {
        let video =
            switch videoCodec {
            case .proRes422: "ProRes 422"
            case .h264: "H.264"
            }
        let audio =
            switch audioCodec {
            case .linearPCM: "PCM"
            case .aac: "AAC"
            }
        return "\(video) · \(audio) · \(fileExtension.uppercased())"
    }
}

/// Texts and stored options of "Export for editing…".
public enum EditingExportContent {
    /// `UserDefaults` key of the "also write a JSON sidecar" switch; on by default.
    public static let writesSidecarKey = "export.writesSidecar"
    public static let menuTitle = String(localized: "Export for Editing…", bundle: .module)
    public static let sidecarToggleTitle = String(localized: "Include JSON Sidecar", bundle: .module)
    public static let folderPrompt = String(localized: "Export Here", bundle: .module)
    public static let folderMessage = String(
        localized: "Choose a folder for the exported take. Existing files are never replaced.", bundle: .module)

    /// `detail` is what went wrong, as the media layer describes it.
    public static func failure(detail: String) -> UserMessage {
        UserMessage(title: String(localized: "Can't export the result", bundle: .module), message: detail)
    }
}
