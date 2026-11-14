import Foundation

public enum ValidationIssue: Sendable, Hashable {
    /// The selected range isn't finite or doesn't lie within the source file.
    case selectionOutsideSource
    /// No source video, and the model can't make a clip without one.
    case sourceRequired
    /// A clip made without a source has neither a prompt nor an image to go on, or Edit or Extend has no prompt.
    case promptRequired
    /// A frame side below one pixel.
    case invalidFrameSize(PixelSize)
    case durationTooShort(TimeInterval)
    case durationTooLong(TimeInterval)
    case tooFewReferences(minimum: Int)
    case tooManyReferences(maximum: Int)
    case presetRequired
    /// Object swap frame below the API minimum and the user hasn't allowed an upscale.
    case frameTooSmall(PixelSize)
    /// Length counted in Unicode scalars, as the API's JSON schema does.
    case promptTooLong(length: Int)
    /// A model that voices a speech (`VideoModelDescriptor.Control.speech`) has none.
    case speechRequired
    /// The speech outside the model's window (`VideoModelDescriptor.speechSeconds`), in seconds.
    case speechTooShort(TimeInterval)
    case speechTooLong(TimeInterval)
    /// A model that voices a speech makes the clip from images alone and takes no source video.
    case sourceNotTaken
}
