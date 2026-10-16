import Foundation
import JutsuCore

extension CreateForm {
    /// The form's inputs as a template; the source and ranges are left out.
    public func makeTemplate(name: String, id: UUID = UUID(), createdAt: Date = Date()) -> JobTemplate {
        JobTemplate(
            id: id, name: name, createdAt: createdAt, mode: mode, model: selectedModel,
            references: usesFrames ? frames.images : references, presetID: presetID, prompt: prompt,
            resolution: resolution,
            audio: jobAudio, bitrate: jobBitrate, characterOrientation: jobCharacterOrientation,
            cinemaControls: jobCinemaControls, referencesAreFrames: usesFrames)
    }

    /// Fills the inputs from `template`. A loaded source and its ranges stay, so only the video is left to add,
    /// cut to the model's limits. A model outside `offered` runs on Genjutsu, and the message says so.
    @discardableResult
    public mutating func apply(_ template: JobTemplate, offered: Set<VideoModel> = [.genjutsu]) -> UserMessage? {
        mode = template.mode
        let runsOnModel = offered.contains(template.model)
        model = runsOnModel ? template.model : .genjutsu
        if template.referencesAreFrames && model.declares(.frames) {
            references = []
            frames = FramePair(template.references)
        } else {
            references = Array(template.references.prefix(limits.referenceImages.upperBound))
            frames = FramePair()
        }
        if template.mode.limits.requiresPreset { presetID = template.presetID }
        prompt = template.prompt
        resolution = template.resolution
        audio = template.audio
        if let bitrate = template.bitrate { picks.bitrate = bitrate }
        if let orientation = template.characterOrientation { picks.orientation = orientation }
        if model.declares(.cinemaControls) { cinemaControls = template.cinemaControls }
        guard !runsOnModel else { return nil }
        return UserMessage(
            title: String(localized: "Running on Genjutsu", bundle: .module),
            message: String(
                localized: "\"\(template.name)\" uses \(template.model.title), which this connection doesn't offer.",
                bundle: .module))
    }
}

extension LibraryItemModel {
    /// The inputs "Save as Template" keeps. A draft's resolution is a draft setting, so it becomes `finalResolution`;
    /// a Kling draft's is its quality, so it stays.
    public func templateSpec(finalResolution: Resolution) -> JobSpec {
        spec.isDraft && spec.model.offersDraft ? finalSpec(at: finalResolution) : spec
    }
}

/// Template names: what the save field starts with, and how a taken name is made unique.
public enum TemplateNaming {
    static let maximumLength = 60
    static let fallback = String(localized: "Untitled template", bundle: .module)

    /// "Restyle · rainy neon street": the mode and the start of the prompt's first line.
    public static func suggestedName(mode: Mode, prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = firstLine.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return mode.shortTitle }
        return truncated("\(mode.shortTitle) · \(words)")
    }

    /// "Image · a knight in silver armor": the kind and the start of the prompt's first line.
    public static func suggestedName(kind: TemplateKind, prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = firstLine.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return kind.title }
        return truncated("\(kind.title) · \(words)")
    }

    /// `proposed` trimmed and cut to length; when another template already has it (ignoring case),
    /// " 2", " 3"… is appended. `existing` must not contain the name of the template being renamed.
    public static func uniqueName(_ proposed: String, among existing: [String]) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = truncated(trimmed.isEmpty ? fallback : trimmed)
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    private static func truncated(_ name: String) -> String {
        guard name.count > maximumLength else { return name }
        return String(name.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension JobTemplate {
    /// "Motion · Seedance 2.5 · 2 images · 720p · Mute" under the template's name; Genjutsu isn't named.
    /// An image template reads "Image · Soul 2 · 16:9 · 4 variants".
    public var summary: String {
        if kind == .image {
            var parts = [TemplateKind.image.title]
            if let model = imageModelTitle { parts.append(model) }
            if let ratio = imageAspectRatio { parts.append(ratio) }
            if imageCount > 1 {
                parts.append(String(localized: "\(imageCount) variants", bundle: .module))
            } else if !references.isEmpty {
                parts.append(String(localized: "\(references.count) images", bundle: .module))
            }
            return parts.joined(separator: " · ")
        }
        var parts = [mode.shortTitle]
        if model != .genjutsu { parts.append(model.title) }
        if referencesAreFrames {
            parts.append(
                references.count > 1
                    ? String(localized: "Start and end frames", bundle: .module)
                    : String(localized: "Start frame", bundle: .module))
        } else if !references.isEmpty {
            parts.append(String(localized: "\(references.count) images", bundle: .module))
        }
        parts.append(resolution.title(on: model))
        if audio != .original { parts.append(audio.title) }
        return parts.joined(separator: " · ")
    }
}
