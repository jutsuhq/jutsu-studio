import Foundation
import HiggsfieldAPI
import JutsuCore

/// The REST request of each job: the endpoint (`JobSpec.endpointID`, from the catalog) and that endpoint's body, by
/// the model's request shape. Mirrors `AccountModel.request` for the account, except that Seedance's mode and
/// Kling's quality are the endpoint, and Kling takes no duration (the output follows the source) and has no
/// background parameter.
struct APIModel {
    /// The model parameters the REST API sends: all but Kling's background, which it has no parameter for.
    static let parameters = Set(ModelParameter.allCases).subtracting([.klingVideoBackground])

    let endpoint: ModelEndpoint
    let body: any Encodable & Sendable

    init(_ spec: JobSpec, inputs: RemoteInputs) throws {
        guard spec.operation == nil else { throw APIModel.needsAccount }
        guard let endpoint = ModelEndpoint(rawValue: spec.endpointID) else {
            throw ProviderError.validation(
                field: nil,
                message: String(localized: "\(spec.model.title) can't run with an API key.", bundle: .module))
        }
        self.endpoint = endpoint
        switch spec.model.descriptor.shape {
        case .genjutsu: body = try Self.genjutsu(spec, inputs: inputs)
        case .seedance where spec.mode.isVideoOperation: body = try Self.seedanceVideo(spec, inputs: inputs)
        case .seedance where spec.usesFrames: body = try Self.seedanceFrames(spec, inputs: inputs)
        case .seedance: body = Self.seedance(spec, inputs: inputs)
        case .klingMotionControl: body = try Self.kling(spec, inputs: inputs)
        case .klingVideoReference: body = try Self.klingVideoReference(spec, inputs: inputs)
        case .klingVideoEdit: body = try Self.klingVideoEdit(spec, inputs: inputs)
        case .wanReference, .cinemaStudio: body = try Self.referenceToVideo(spec, inputs: inputs)
        }
    }

    /// Restyle can't go without a preset, and no Genjutsu mode without a video.
    /// Upscale and Remove Background are tools of the account's MCP server; the public REST docs have neither.
    static let needsAccount = ProviderError.validation(
        field: nil, message: String(localized: "Needs a Higgsfield account", bundle: .module))

    static func genjutsu(_ spec: JobSpec, inputs: RemoteInputs) throws -> GenerationRequest {
        guard let video = inputs.video else {
            throw ProviderError.validation(
                field: "video", message: String(localized: "Genjutsu needs a source video.", bundle: .module))
        }
        var presetID: UUID?
        if spec.mode == .restyle {
            guard let preset = spec.presetID else {
                throw ProviderError.validation(
                    field: "preset_id", message: String(localized: "Restyle needs a preset.", bundle: .module))
            }
            presetID = preset
        }
        return GenerationRequest(
            videoURL: video.url, imageURLs: inputs.images.map(\.url), prompt: spec.prompt,
            resolution: spec.resolution.rawValue, presetID: presetID)
    }

    /// The source clip goes first in `video_urls`. The soundtrack is generated as on the account
    /// (`AccountModel.generatesAudio`).
    static func seedance(_ spec: JobSpec, inputs: RemoteInputs) -> SeedanceRequest {
        SeedanceRequest(
            prompt: spec.prompt, imageURLs: inputs.images.map(\.url), videoURLs: inputs.video.map { [$0.url] } ?? [],
            duration: AccountModel.durationSeconds(of: spec), resolution: spec.resolution.rawValue,
            aspectRatio: aspectRatio(of: spec)?.rawValue, generateAudio: AccountModel.generatesAudio(spec),
            bitrateMode: spec.bitrate?.rawValue)
    }

    /// The first image is the start frame, the second, when there is one, the end frame.
    static func seedanceFrames(_ spec: JobSpec, inputs: RemoteInputs) throws -> SeedanceFramesRequest {
        guard let start = inputs.images.first else {
            throw ProviderError.validation(
                field: "image_url", message: String(localized: "Seedance needs the start frame.", bundle: .module))
        }
        return SeedanceFramesRequest(
            prompt: spec.prompt, imageURL: start.url, endImageURL: inputs.images.dropFirst().first?.url,
            duration: AccountModel.durationSeconds(of: spec), resolution: spec.resolution.rawValue,
            generateAudio: AccountModel.generatesAudio(spec), bitrateMode: spec.bitrate?.rawValue)
    }

    /// Edit and Extend: the source is the clip to change or continue. Edit's output follows the source, so it takes
    /// no length; Extend's `duration` is the part it adds. Edit keeps the source's sound like the other source jobs
    /// (put back after download) unless the model is asked to make one, while Extend has no source sound for the new
    /// part, so the model makes it unless the job is muted.
    static func seedanceVideo(_ spec: JobSpec, inputs: RemoteInputs) throws -> SeedanceVideoRequest {
        guard let video = inputs.video else {
            throw ProviderError.validation(
                field: "video_url",
                message: String(localized: "Seedance needs the clip to edit or extend.", bundle: .module))
        }
        let isExtend = spec.mode == .extend
        return SeedanceVideoRequest(
            prompt: spec.prompt, videoURL: video.url, imageURLs: inputs.images.map(\.url),
            duration: isExtend ? AccountModel.durationSeconds(of: spec) : nil, resolution: spec.resolution.rawValue,
            generateAudio: AccountModel.generatesAudio(spec), bitrateMode: spec.bitrate?.rawValue)
    }

    /// The REST schema has no "auto" and defaults to 16:9, so a clip from a source asks for the ratio nearest the
    /// source's frame among `candidates`; without a source, the one asked for, or the server's default for Auto.
    static func aspectRatio(of spec: JobSpec, among candidates: [AspectRatio] = AspectRatio.allCases) -> AspectRatio? {
        guard let source = spec.source else { return spec.aspectRatio == .auto ? nil : spec.aspectRatio }
        return AspectRatio.nearest(to: source.pixelSize, among: candidates)
    }

    /// Kling O3 takes the source as its one reference video and the images in order, and makes a clip as long as the
    /// selection inside its 3–10 s (`durationSeconds`), at its quality (`KlingQuality`).
    static func klingVideoReference(_ spec: JobSpec, inputs: RemoteInputs) throws -> KlingVideoReferenceRequest {
        guard let video = inputs.video else {
            throw ProviderError.validation(
                field: "video_urls",
                message: String(localized: "\(spec.model.title) needs a source video.", bundle: .module))
        }
        return KlingVideoReferenceRequest(
            prompt: spec.prompt, videoURL: video.url, imageURLs: inputs.images.map(\.url),
            quality: KlingQuality(spec.resolution) == .pro ? .pro : .standard,
            duration: AccountModel.durationSeconds(of: spec))
    }

    /// Kling O3's Edit takes the source as the clip to change and the images in order, at its quality; the output
    /// follows the source, so there is no length.
    static func klingVideoEdit(_ spec: JobSpec, inputs: RemoteInputs) throws -> KlingVideoEditRequest {
        guard let video = inputs.video else {
            throw ProviderError.validation(
                field: "video_urls",
                message: String(localized: "\(spec.model.title) needs a source video.", bundle: .module))
        }
        return KlingVideoEditRequest(
            prompt: spec.prompt, videoURL: video.url, imageURLs: inputs.images.map(\.url),
            quality: KlingQuality(spec.resolution) == .pro ? .pro : .standard)
    }

    /// Wan, Cinema Studio and MiniMax H3 take the source as their reference video and the images in order, and make
    /// a clip as long as the selection inside the model's limits (`durationSeconds`) at one of the model's
    /// resolutions. The frame is the one of the model's `aspectRatios` nearest the source's, else the server's
    /// default (Wan 3.0's `adaptive`, MiniMax's `auto`). A model with a soundtrack (`generatedAudio`) makes one as
    /// Seedance does (`generatesAudio`), and Cinema Studio sends the creative controls the job sets.
    static func referenceToVideo(_ spec: JobSpec, inputs: RemoteInputs) throws -> ReferenceToVideoRequest {
        guard let video = inputs.video else {
            throw ProviderError.validation(
                field: "video_urls",
                message: String(localized: "\(spec.model.title) needs a source video.", bundle: .module))
        }
        let frames = spec.model.descriptor.aspectRatios
        return ReferenceToVideoRequest(
            prompt: spec.prompt, videoURL: video.url, imageURLs: inputs.images.map(\.url),
            duration: AccountModel.durationSeconds(of: spec), resolution: spec.resolution.rawValue,
            aspectRatio: frames.isEmpty ? nil : aspectRatio(of: spec, among: frames)?.rawValue,
            generateAudio: spec.model.declares(.generatedAudio) ? AccountModel.generatesAudio(spec) : nil,
            controls: spec.model.declares(.cinemaControls) ? spec.cinemaControls.fields : [:])
    }

    /// Kling takes exactly one character image and the source as the motion.
    static func kling(_ spec: JobSpec, inputs: RemoteInputs) throws -> KlingMotionRequest {
        guard let video = inputs.video else {
            throw ProviderError.validation(
                field: "video_url", message: String(localized: "Kling needs a source video.", bundle: .module))
        }
        guard let image = inputs.images.first else {
            throw ProviderError.validation(
                field: "image_url", message: String(localized: "Kling needs a reference image.", bundle: .module))
        }
        return KlingMotionRequest(
            imageURL: image.url, videoURL: video.url, prompt: spec.prompt,
            keepOriginalSound: AccountModel.keepsOriginalSound(spec) ? .keep : .drop,
            characterOrientation: spec.characterOrientation.flatMap {
                KlingMotionRequest.Orientation(rawValue: $0.rawValue)
            })
    }
}
