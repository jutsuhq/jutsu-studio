import Foundation

/// API input rules shared by all providers.
public enum Validation {
    public static let durationRange: ClosedRange<TimeInterval> = 4...30
    public static let objectSwapMinimumPixels = 409_600
    public static let maximumPromptLength = 10_000

    /// Empty when the spec can be submitted; limits by `constraints` where they say.
    public static func check(_ spec: JobSpec, constraints: ModelConstraintTable = .builtIn) -> [ValidationIssue] {
        let limits = spec.limits(in: constraints)
        var issues = sourceIssues(spec)
        // The selection's length means nothing until the selection is inside the video.
        if !issues.contains(.selectionOutsideSource), let issue = durationIssue(spec, limits: limits.duration) {
            issues.append(issue)
        }

        if spec.references.count < limits.referenceImages.lowerBound {
            issues.append(.tooFewReferences(minimum: limits.referenceImages.lowerBound))
        } else if spec.references.count > limits.referenceImages.upperBound {
            issues.append(.tooManyReferences(maximum: limits.referenceImages.upperBound))
        }

        if limits.requiresPreset && spec.presetID == nil {
            issues.append(.presetRequired)
        }

        if let issue = frameIssue(spec) {
            issues.append(issue)
        }

        let promptLength = spec.prompt.unicodeScalars.count
        if promptLength > maximumPromptLength {
            issues.append(.promptTooLong(length: promptLength))
        }
        return issues
    }

    /// A selection outside the video; without a video, a model that needs one, or nothing to go on; Edit, Extend
    /// and a model that needs a prompt (`requiresPrompt`) without one, also without a video unless the clip starts
    /// from frames (Kling 4.0's `image-to-video` is the one of its endpoints that takes no prompt).
    private static func sourceIssues(_ spec: JobSpec) -> [ValidationIssue] {
        let tolerance = Pricing.durationTolerance
        let hasPrompt = !spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let source = spec.source else {
            if !spec.model.makesClipsWithoutSource || spec.mode != .motionTransfer { return [.sourceRequired] }
            if hasPrompt { return [] }
            if spec.model.descriptor.requiresPrompt { return spec.usesFrames ? [] : [.promptRequired] }
            return spec.references.isEmpty ? [.promptRequired] : []
        }
        let range = source.range
        let isInside =
            source.duration.isFinite && range.lowerBound.isFinite && range.upperBound.isFinite
            && range.lowerBound >= -tolerance && range.upperBound <= source.duration + tolerance
        var issues: [ValidationIssue] = isInside ? [] : [.selectionOutsideSource]
        if (spec.mode.isVideoOperation || spec.model.descriptor.requiresPrompt) && !hasPrompt {
            issues.append(.promptRequired)
        }
        return issues
    }

    /// The source selection, or the length of a clip without one, outside the model's window; for Extend, the
    /// selection or the added length.
    private static func durationIssue(_ spec: JobSpec, limits: ClosedRange<TimeInterval>) -> ValidationIssue? {
        let tolerance = Pricing.durationTolerance
        var durations = [spec.source?.selectedDuration ?? spec.duration]
        if spec.mode == .extend { durations.append(spec.duration) }
        for duration in durations {
            if duration < limits.lowerBound - tolerance { return .durationTooShort(duration) }
            if duration > limits.upperBound + tolerance { return .durationTooLong(duration) }
        }
        return nil
    }

    /// The source's frame; a clip made without a source has none to check.
    private static func frameIssue(_ spec: JobSpec) -> ValidationIssue? {
        guard let source = spec.source else { return nil }
        let size = source.pixelSize
        if !size.isValid { return .invalidFrameSize(size) }
        if spec.mode == .objectSwap && size.pixelCount < objectSwapMinimumPixels && !source.allowsUpscale {
            return .frameTooSmall(size)
        }
        return nil
    }

    /// Smallest size with the same aspect ratio, even sides (H.264 needs them) and at least
    /// `objectSwapMinimumPixels`. Sizes already large enough are returned unchanged.
    public static func upscaledSize(width: Int, height: Int) -> PixelSize {
        let size = PixelSize(width: width, height: height)
        guard width > 0, height > 0, size.pixelCount < objectSwapMinimumPixels else { return size }
        let scale = (Double(objectSwapMinimumPixels) / Double(size.pixelCount)).squareRoot()
        // The slack keeps 480.0000000001 at 480; the exact result is the fallback if that lands short.
        let scaled = { (slack: Double) in
            let evenCeil = { (side: Int) in Int((Double(side) * scale / 2 - slack).rounded(.up)) * 2 }
            return PixelSize(width: evenCeil(width), height: evenCeil(height))
        }
        let tight = scaled(1e-9)
        return tight.pixelCount >= objectSwapMinimumPixels ? tight : scaled(0)
    }
}
