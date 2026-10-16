import Foundation
import HiggsfieldCore

/// One call of a tool that works on an existing video: `upscale_video`, `reframe`, `remove_background`, `dubbing`
/// or `voice_change`.
///
/// Built against the live catalog of 2026-10-15 (`docs/mcp-snapshots/2026-10-15.json`): each tool takes one
/// `params` object, which names the video as a confirmed upload's `media_id` or a finished generation's job ID under
/// the same key. Only `reframe` declares `get_cost`; the others refuse unknown keys, and are quoted through
/// `generate_video` instead (`Operation.quoteModel`). Each answers like
/// `generate_video` (`results[].id`), and the job is read with `job_status`.
public struct VideoEdit: Sendable, Hashable {
    public enum Operation: Sendable, Hashable {
        /// `bytedance`: `resolution` "1080p", "2k" or "4k", the source's `width` and `height` (required), `fps` 24,
        /// 30 or 60 (`nil` for the server's default, 24). `topaz`: `resolution` "1080p" or "2160p", no size and no
        /// frame rate.
        case upscale(resolution: String, fps: Int?, provider: Provider, width: Int?, height: Int?)
        case removeBackground
        /// `aspectRatio` "9:16" and the like. The source's length in seconds (at most 60) and a resolution ("480p",
        /// "720p", "1080p") price the call, and are sent with it for a source longer than `reframeShortSource`.
        case reframe(aspectRatio: String, durationSeconds: Double, resolution: String)
        /// `language` is an ISO 639-3 code ("fra").
        case dub(language: String)
        /// The pair `list_voices` names a voice by.
        case changeVoice(voiceID: String, voiceType: String)

        var role: ToolRole {
            switch self {
            case .upscale: .upscaleVideo
            case .removeBackground: .removeBackground
            case .reframe: .reframe
            case .dub: .dubbing
            case .changeVoice: .voiceChange
            }
        }

        /// The catalog model `generate_video` quotes the operation as, with `get_cost` and the source's whole
        /// seconds; `nil` for `reframe`, which its own tool quotes, and for Topaz, which answers that it has no cost
        /// estimation. The operation tools take no `get_cost` (they reject an unknown key, and a tool that ignored it
        /// would run and charge), but the catalog lists each operation as a video model priced by length, an upscale
        /// also by its resolution and frame rate. Checked live on 2026-10-15: a 7.04 s dub was billed 21 credits, the
        /// quote for 7 s.
        public var quoteModel: String? {
            switch self {
            case .dub: "dubbing"
            case .changeVoice: "voice_change"
            case .removeBackground: "video_background_remover"
            case .upscale(_, _, .bytedance, _, _): "bytedance_video_upscale"
            case .upscale, .reframe: nil
            }
        }
    }

    public enum Provider: String, Sendable, Hashable {
        case bytedance
        case topaz
    }

    /// What the tool works on. Every tool takes either under the same key.
    public enum Input: Sendable, Hashable {
        /// A finished generation of the account, by its job ID: nothing is uploaded.
        case job(String)
        /// A confirmed upload.
        case media(String)

        var id: String {
            switch self {
            case .job(let id), .media(let id): id
            }
        }
    }

    /// The length up to which `reframe` takes the source alone ("for source videos over 15 seconds, pass
    /// duration_seconds and resolution").
    public static let reframeShortSource: TimeInterval = 15

    public var operation: Operation
    public var input: Input

    public init(operation: Operation, input: Input) {
        self.operation = operation
        self.input = input
    }

    var role: ToolRole { operation.role }

    /// The arguments of the call that runs the operation: `params` with the input under the tool's key, then the
    /// operation's own.
    var arguments: [String: JSONValue] {
        var params: [String: JSONValue]
        switch operation {
        case .upscale(let resolution, let fps, let provider, let width, let height):
            params = [
                ToolKey.videoID: .string(input.id), ToolKey.provider: .string(provider.rawValue),
                ToolKey.resolution: .string(resolution),
            ]
            if let fps { params[ToolKey.fps] = .number(Double(fps)) }
            if let width { params[ToolKey.width] = .number(Double(width)) }
            if let height { params[ToolKey.height] = .number(Double(height)) }
        case .removeBackground:
            params = [ToolKey.mediaID: .string(input.id), ToolKey.mediaType: .string(ToolKey.video)]
        case .reframe(let aspectRatio, let durationSeconds, let resolution):
            params = [
                ToolKey.medias: .array([[ToolKey.role: .string(ToolKey.video), ToolKey.value: .string(input.id)]]),
                ToolKey.aspectRatio: .string(aspectRatio),
            ]
            if durationSeconds > Self.reframeShortSource {
                params[ToolKey.durationSeconds] = .number(durationSeconds)
                params[ToolKey.resolution] = .string(resolution)
            }
        case .dub(let language):
            params = [ToolKey.videoID: .string(input.id), ToolKey.targetLanguage: .string(language)]
        case .changeVoice(let voiceID, let voiceType):
            params = [
                ToolKey.videoID: .string(input.id), ToolKey.voiceID: .string(voiceID),
                ToolKey.voiceType: .string(voiceType),
            ]
        }
        return [ToolKey.params: .object(params)]
    }

    /// The arguments of `reframe`'s price question; `nil` for the other operations. `reframe` is priced by the
    /// source's length and the resolution alone, so a quote names no video.
    static func quoteArguments(_ operation: Operation) -> [String: JSONValue]? {
        guard case .reframe(_, let durationSeconds, let resolution) = operation else { return nil }
        return [
            ToolKey.params: [
                ToolKey.getCost: true, ToolKey.durationSeconds: .number(durationSeconds),
                ToolKey.resolution: .string(resolution),
            ]
        ]
    }

    /// The arguments of `generate_video`'s price question for an operation (`Operation.quoteModel`), `nil` without
    /// such a model. `duration` is whole seconds, at least 1, as the schema's `duration` is an integer. An upscale
    /// also sends its `resolution` and `fps`: not in the schema, but the live server prices by them (10 s at 1080p
    /// 2 credits, at 4K 8, at 4K and 60 fps 15).
    static func generateQuoteArguments(_ operation: Operation, duration: TimeInterval) -> [String: JSONValue]? {
        guard let model = operation.quoteModel, duration > 0,
            let seconds = ModelLimits.count(max(1, duration.rounded()))
        else { return nil }
        var params: [String: JSONValue] = [
            ToolKey.model: .string(model), ToolKey.getCost: true,
            ToolKey.duration: .number(Double(seconds)),
        ]
        if case .upscale(let resolution, let fps, _, _, _) = operation {
            params[ToolKey.resolution] = .string(resolution)
            if let fps { params[ToolKey.fps] = .number(Double(fps)) }
        }
        return [ToolKey.params: .object(params)]
    }
}

extension MCPTool {
    /// The keys the tool's `params` object declares, over every `oneOf` variant.
    var paramsArgumentNames: Set<String> {
        guard let params = inputSchema["properties"]?[ToolKey.params] else { return [] }
        let variants = [params] + (params["oneOf"]?.arrayValue ?? [])
        return Set(variants.flatMap { ($0["properties"]?.objectValue ?? [:]).keys })
    }
}

extension HiggsfieldAccount {
    /// Throws `HiggsfieldError.toolUnavailable` when the account has no tool for `operation`.
    public func checkTool(for operation: VideoEdit.Operation) async throws {
        guard try await lookUp(operation.role, recheckingAfter: Self.optionalToolRecheck) != nil else {
            throw HiggsfieldError.toolUnavailable(operation.role.rawValue)
        }
    }

    /// The price in credits; submits nothing. `reframe` asks its own tool, when its schema still declares
    /// `get_cost`; the others ask `generate_video` for their catalog model (`VideoEdit.Operation.quoteModel`) and the
    /// source's `duration` in seconds. `nil`, without a call, with neither, and `nil` when the answer names no price
    /// or the question fails: the price is then unknown, which the sheet says, rather than the sheet failing.
    public func cost(of operation: VideoEdit.Operation, duration: TimeInterval? = nil) async throws -> Double? {
        if let arguments = VideoEdit.quoteArguments(operation) {
            guard let tool = try await lookUp(operation.role, recheckingAfter: Self.optionalToolRecheck),
                tool.paramsArgumentNames.contains(ToolKey.getCost)
            else { return nil }
            return Self.credits(in: try await call(operation.role, arguments)[ToolKey.cost])
        }
        guard let duration, duration > 0,
            let arguments = VideoEdit.generateQuoteArguments(operation, duration: duration)
        else { return nil }
        do {
            return Self.credits(in: try await call(.generate, arguments)[ToolKey.cost])
        } catch HiggsfieldError.validation {
            // A model the quote doesn't take: the price is shown after the run.
            return nil
        }
    }

    /// Not idempotent, like `generate(_:)`: no tool takes an idempotency key. The job ID is read like
    /// `execute_preset`'s, in any of the shapes it may come in (the catalog names `results[].id`); a reply that names
    /// no job and gives no reason throws `.server(status: 200)`, as it may have started one. The result is read with
    /// `status(of:)`.
    public func run(_ edit: VideoEdit) async throws -> Generation {
        let value = try await call(edit.role, edit.arguments)
        guard let id = PresetQuote.jobID(in: value) else { throw Self.noJobStarted(value) }
        return Generation(
            id: id, requestID: value[ToolKey.requestID]?.stringValue, credits: Self.credits(in: value[ToolKey.cost]))
    }
}
