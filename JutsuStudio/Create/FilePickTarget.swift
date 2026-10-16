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

    var contentTypes: [UTType] {
        switch self {
        case .source: [.movie]
        case .references, .characterSet, .frame: [.image]
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .source, .frame: false
        case .references, .characterSet: true
        }
    }
}
