import Foundation
import HiggsfieldMCP
import JutsuCore

/// Genjutsu's galleries in the app's terms: styles become `StylePreset`s keyed by the UUID in their ID, motion
/// entries become `MotionPreset`s.
enum GenjutsuMapping {
    static let stylePrefix = "genjutsu-style:"

    /// The ID `execute_preset` takes for the style `JobSpec.presetID` names.
    static func styleID(_ presetID: UUID) -> String {
        stylePrefix + presetID.uuidString.lowercased()
    }

    /// `nil` for anything but a style with a still preview.
    static func style(_ preset: GenjutsuPreset) -> StylePreset? {
        guard preset.id.hasPrefix(stylePrefix), let id = preset.uuid, let still = preset.thumbnailURL else {
            return nil
        }
        return StylePreset(id: id, name: preset.name, previewURL: still, previewVideoURL: preset.previewURL)
    }

    /// `nil` for an entry without a driving video, which can't be a source.
    static func motion(_ preset: GenjutsuPreset) -> MotionPreset? {
        guard let video = preset.drivingVideoURL else { return nil }
        let mode: Mode? =
            switch preset.exampleModel {
            case VideoRequest.Model.motionControl?: .motionTransfer
            case VideoRequest.Model.replaceObject?: .objectSwap
            default: nil
            }
        return MotionPreset(
            id: preset.id, name: preset.name, videoURL: video, thumbnailURL: preset.thumbnailURL,
            previewURL: preset.previewURL, exampleMode: mode)
    }

    /// `nil` for the account's uploads, which aren't a gallery.
    static func category(_ shelf: MotionShelf) -> GenjutsuCategory? {
        switch shelf {
        case .featured: .higgsfield
        case .trending: .trending
        case .new: .new
        case .uploads: nil
        }
    }
}
