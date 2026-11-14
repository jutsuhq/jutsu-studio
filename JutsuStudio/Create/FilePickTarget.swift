import JutsuCore
import Presentation
import UniformTypeIdentifiers

/// What the shared file picker is open for.
enum FilePickTarget {
    case source
    case references
    /// The images of one new batch character.
    case characterSet
    /// One of Seedance's start and end frames.
    case frame(FrameSlot)
    /// The recording the characters say (`CreateForm.speech`).
    case speech

    var contentTypes: [UTType] {
        switch self {
        case .source: [.movie]
        case .references, .characterSet, .frame: [.image]
        case .speech: [.audio]
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .source, .frame, .speech: false
        case .references, .characterSet: true
        }
    }
}
