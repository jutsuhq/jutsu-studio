import Foundation
import JutsuCore

// The saved draft (`CreateDraftStore`) is one flat object: the grouped properties (`picks`, `frames`, `batch`) read
// and write their own keys beside the form's, under the names they had before they were grouped, so drafts saved
// earlier still decode. A key is required or optional as in the form's own synthesized coding.
extension CreateForm {
    private enum CodingKeys: String, CodingKey {
        case mode, model, source, ranges, selectedRangeIndex, references, presetID, prompt, resolution
        case draftResolution, draftLength, allowsUpscale, audio, keepsVideoBackground, length, aspectRatio
        case parentID, remoteInputs, constraints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        resolution = try container.decode(Resolution.self, forKey: .resolution)
        draftResolution = try container.decode(Resolution.self, forKey: .draftResolution)
        model = try container.decode(VideoModel.self, forKey: .model)
        source = try container.decodeIfPresent(SourceVideo.self, forKey: .source)
        ranges = try container.decode([ClosedRange<TimeInterval>].self, forKey: .ranges)
        selectedRangeIndex = try container.decode(Int.self, forKey: .selectedRangeIndex)
        references = try container.decode([LocalImage].self, forKey: .references)
        presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
        prompt = try container.decode(String.self, forKey: .prompt)
        draftLength = try container.decode(DraftLength.self, forKey: .draftLength)
        allowsUpscale = try container.decode(Bool.self, forKey: .allowsUpscale)
        audio = try container.decode(AudioOption.self, forKey: .audio)
        keepsVideoBackground = try container.decode(Bool.self, forKey: .keepsVideoBackground)
        length = try container.decode(TimeInterval.self, forKey: .length)
        aspectRatio = try container.decode(AspectRatio.self, forKey: .aspectRatio)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        remoteInputs = try container.decodeIfPresent(RemoteInputs.self, forKey: .remoteInputs)
        constraints = try container.decodeIfPresent(ModelConstraintTable.self, forKey: .constraints)
        picks = try ModelPicks(from: decoder)
        frames = try FramePair(from: decoder)
        batch = try CreateBatch(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(ranges, forKey: .ranges)
        try container.encode(selectedRangeIndex, forKey: .selectedRangeIndex)
        try container.encode(references, forKey: .references)
        try container.encodeIfPresent(presetID, forKey: .presetID)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(draftResolution, forKey: .draftResolution)
        try container.encode(draftLength, forKey: .draftLength)
        try container.encode(allowsUpscale, forKey: .allowsUpscale)
        try container.encode(audio, forKey: .audio)
        try container.encode(keepsVideoBackground, forKey: .keepsVideoBackground)
        try container.encode(length, forKey: .length)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(remoteInputs, forKey: .remoteInputs)
        try container.encodeIfPresent(constraints, forKey: .constraints)
        try picks.encode(to: encoder)
        try frames.encode(to: encoder)
        try batch.encode(to: encoder)
    }
}
