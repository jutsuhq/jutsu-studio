import Foundation
import JutsuAgent
import JutsuCore

/// What the app read of an item an agent asked to enhance on this Mac (`AgentOnDeviceRuns.Target`).
public enum AgentOnDeviceMedia: Sendable, Hashable {
    /// A video's size, frame rate and length.
    case video(PixelSize, frameRate: Double, duration: TimeInterval)
    /// A video whose file can't be read.
    case unreadableVideo
    /// An image's upright size; `nil` when it can't be read.
    case image(PixelSize?)
}

// The sheet's rules for an agent's run on this Mac, and the words it is refused with.
extension AgentOnDeviceRuns {
    /// The `kind` its runs have in `jobs` and in the request log.
    public static let kind = "on_device"

    /// The run the fields name on this item.
    static func action(_ fields: EnhanceCommand, on media: AgentOnDeviceMedia) throws(AgentError) -> OnDeviceAction {
        let isImage = if case .image = media { true } else { false }
        switch fields.operation {
        case .smoothMotion:
            guard !isImage else {
                throw AgentError(
                    .invalidRequest, message: "smooth_motion runs on a video; this item is an image.",
                    retryable: false, next: "Pick a video's Library ID (library_search with kind video).")
            }
            guard let mode = fields.mode.flatMap(AgentSmoothMotion.init(rawValue:)) else {
                throw .badRequest(
                    "smooth_motion needs mode: \(AgentSmoothMotion.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .smoothMotion(SmoothMotion(mode))
        case .upscale where fields.isOnDevice:
            var target = OnDeviceUpscale.Target.full
            if let name = fields.target {
                guard let named = OnDeviceUpscale.Target(name: name) else {
                    throw .badRequest(
                        "upscale with engine mac takes target \(OnDeviceUpscale.Target.names); left out it is 4×")
                }
                target = named
            }
            return isImage ? .upscaleImage(target) : .upscaleVideo(target)
        default:
            throw .badRequest("\(fields.operation.rawValue) runs on Higgsfield, not on this Mac")
        }
    }

    /// Why the sheet wouldn't start `action` on the target now, in the order an agent can act on: the engine, the
    /// file, a run already going on the item, and last the person's agreement to the model download, so the person is
    /// only asked for a run that can go.
    static func refusal(_ action: OnDeviceAction, on target: Target, runs: OnDeviceRuns) -> AgentError? {
        let item = target.source.materialID
        guard runs.supports(action.engine) else { return unavailable(action) }
        switch (action, target.media) {
        case (_, .unreadableVideo), (_, .image(nil)):
            return AgentError(
                .failed, message: "The item's file can't be read.", retryable: false,
                next: "Call library_get with its ID to check its file.")
        case (.upscaleVideo, .video(let size, _, _)) where !OnDeviceUpscale.offersVideo(size):
            return tooLarge("videos", size, limit: OnDeviceUpscale.videoLimit, next: Self.higgsfieldUpscale)
        case (.upscaleImage, .image(let size?)) where !OnDeviceUpscale.offersImage(size):
            return tooLarge(
                "images", size, limit: OnDeviceUpscale.scalerLimit,
                next: "Pick an image up to that size; Higgsfield's upscale here takes videos only.")
        case (.upscaleVideo(let goal), .video(let size, _, _)) where goal.output(for: size) == nil,
            (.upscaleImage(let goal), .image(let size?)) where goal.output(for: size) == nil:
            return unreachable(goal, from: size)
        case (.smoothMotion(let motion), .video(_, let rate, _)) where !motion.isOffered(sourceFrameRate: rate):
            let offered = SmoothMotion.offered(sourceFrameRate: rate).map { AgentSmoothMotion($0).rawValue }
            return AgentError(
                .invalidRequest,
                message: "60fps adds nothing to a clip of 50 frames a second or more; this one has "
                    + "\(Int(rate.rounded())).",
                retryable: false, next: "Use mode \(offered.joined(separator: " or ")).")
        default:
            break
        }
        if let run = runs.run(for: item) {
            return AgentError(
                .busy,
                message: "Item \(item.uuidString) already has a run on this Mac, \(run.id.uuidString) "
                    + "(\(Self.operation(of: run.request.action))); each run adds a version, so the next waits for it.",
                retryable: true,
                next: "Follow it with jobs (ids [\(run.id.uuidString)]) and send enhance again once it is over, or "
                    + "cancel it with job_action if an agent started it.")
        }
        if runs.needsConsent(action.engine) {
            return AgentError(
                .needsPerson,
                message: "Nothing was started: Upscale on this Mac needs macOS to download its model from Apple once, "
                    + "and only the person can agree to that. There is no run to follow in jobs until enhance is sent "
                    + "again.",
                retryable: true,
                next:
                    "Call show with item \(item.uuidString) and sheet upscale_on_mac, which opens the sheet where the "
                    + "person agrees (and may start the upscale there), and tell the person; once they agreed, send "
                    + "enhance again. capabilities' onDevice model says needs_consent until then.")
        }
        return nil
    }

    private static let higgsfieldUpscale = "Upscale it on Higgsfield instead: engine standard, with max_cost (paid)."

    static func unavailable(_ action: OnDeviceAction) -> AgentError {
        switch action {
        case .smoothMotion:
            AgentError(
                .engineUnavailable,
                message:
                    "Smooth Motion needs macOS 15.4 or later with VideoToolbox's frame rate conversion, which this "
                    + "Mac doesn't have.",
                retryable: false, next: "Upscale with engine standard and frame_rate 60 makes 60 fps on Higgsfield.")
        case .upscaleVideo, .upscaleImage:
            AgentError(
                .engineUnavailable,
                message: "Upscale on this Mac needs macOS 26 or later with VideoToolbox's super resolution, which this "
                    + "Mac doesn't have.",
                retryable: false,
                next: action.engine == .videoSuperResolution
                    ? higgsfieldUpscale : "Higgsfield's upscale here takes videos only.")
        }
    }

    private static func tooLarge(_ what: String, _ size: PixelSize, limit: PixelSize, next: String) -> AgentError {
        AgentError(
            .invalidRequest,
            message:
                "Upscale on this Mac takes \(what) up to \(limit.width)×\(limit.height) either way round; this one "
                + "is \(size.width)×\(size.height).",
            retryable: false, next: next)
    }

    private static func unreachable(_ target: OnDeviceUpscale.Target, from size: PixelSize) -> AgentError {
        let most = PixelSize(width: size.width * OnDeviceUpscale.scale, height: size.height * OnDeviceUpscale.scale)
        return AgentError(
            .invalidRequest,
            message: "target \(target.fileSuffix) isn't larger than this item, \(size.width)×\(size.height), or needs "
                + "more than 4×: on this Mac it upscales to at most \(most.width)×\(most.height).",
            retryable: false, next: "Pick a target in between, or leave target out for 4×.")
    }

    /// The sheet's estimate of how long the run takes.
    static func estimate(_ action: OnDeviceAction, _ media: AgentOnDeviceMedia) -> TimeInterval? {
        switch (action, media) {
        case (.smoothMotion, .video(let size, let rate, let duration)):
            OnDeviceEstimate.smoothMotion(duration: duration, frameRate: rate, pixelSize: size)
        case (.upscaleVideo, .video(let size, let rate, let duration)):
            OnDeviceEstimate.upscaleVideo(duration: duration, frameRate: rate, pixelSize: size)
        case (.upscaleImage, .image(let size?)):
            OnDeviceEstimate.upscaleImage(pixelSize: size)
        default:
            nil
        }
    }

    static func operation(of action: OnDeviceAction) -> String {
        if case .smoothMotion = action {
            AgentEnhancement.smoothMotion.rawValue
        } else {
            AgentEnhancement.upscale.rawValue
        }
    }

    static func mode(of action: OnDeviceAction) -> String? {
        if case .smoothMotion(let motion) = action { AgentSmoothMotion(motion).rawValue } else { nil }
    }

    /// A run's ID this Mac no longer knows: a relaunch forgets them. Answered for a known request too, so the same
    /// request never starts a second run, and by `jobs`.
    public static func forgotten(_ id: UUID) -> AgentJob {
        AgentJob(
            id: id, state: "unknown", error: "Jutsu Studio forgets a run on this Mac when it quits.", kind: kind,
            next: "If it finished, its result is on the item's current version: call library_get, or subtitles get, "
                + "with the item's ID. Otherwise send the request again with a new request_id.",
            createdAt: nil)
    }
}
