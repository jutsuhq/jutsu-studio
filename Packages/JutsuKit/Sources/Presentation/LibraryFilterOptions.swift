import Foundation
import JutsuCore

/// What the Library's filter menus offer: only the values the origin's rows have, so a menu never lists a model
/// nothing was made with. A menu with fewer than two values has nothing to choose and is left out, unless it holds a
/// value that can still be cleared.
public struct LibraryFilterOptions: Sendable, Equatable {
    public private(set) var modes: [Mode] = []
    public private(set) var models: [VideoModel] = []
    public private(set) var resolutions: [Resolution] = []
    /// Both drafts and finals are among the videos, so Finish can tell them apart.
    public private(set) var hasDraftsAndFinals = false
    public private(set) var imageModels: [String] = []
    public private(set) var imageAspects: [String] = []

    /// - Parameter rows: the origin's rows before any filter, so a menu keeps its values while one is picked.
    public init(_ rows: [LibraryMediaItem]) {
        var modes = Set<Mode>()
        var models = Set<VideoModel>()
        var resolutions = Set<Resolution>()
        var finishes = Set<Bool>()
        var imageModels = Set<String>()
        var imageAspects = Set<String>()
        for row in rows {
            switch row {
            case .video(let item):
                modes.insert(item.spec.mode)
                models.insert(item.spec.model)
                resolutions.insert(item.spec.resolution)
                finishes.insert(item.spec.isDraft)
            case .localImage, .remoteImage:
                if let model = row.imageModel { imageModels.insert(model) }
                if let aspect = row.aspectRatio { imageAspects.insert(aspect) }
            }
        }
        self.modes = Mode.allCases.filter(modes.contains)
        self.models = VideoModel.allCases.filter(models.contains)
        self.resolutions = Resolution.allCases.filter(resolutions.contains)
        hasDraftsAndFinals = finishes.count == 2
        self.imageModels = imageModels.sorted()
        self.imageAspects = imageAspects.sorted()
    }

    /// Whether `field`'s menu shows: it has a choice to make, or it holds one to undo.
    public func shows(_ field: LibraryFilter.Field, in filter: LibraryFilter) -> Bool {
        switch field {
        case .mode: modes.count > 1 || filter.mode != nil
        case .model: models.count > 1 || filter.model != nil
        case .resolution: resolutions.count > 1 || filter.resolution != nil
        case .finish: hasDraftsAndFinals || filter.finish != .all
        case .imageModel: imageModels.count > 1 || filter.imageModel != nil
        case .imageAspectRatio: imageAspects.count > 1 || filter.imageAspectRatio != nil
        case .starred, .rejected, .sort: true
        }
    }
}
