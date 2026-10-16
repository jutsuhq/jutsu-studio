import Foundation
import JutsuCore

/// What the library grid shows: videos, images, or both, interleaved by date. The tab row carrying it sits
/// between the origin switch and the filter bar, stronger than the filters and weaker than the origin.
public enum LibraryKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case video
    case image

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: String(localized: "All", bundle: .module)
        case .video: String(localized: "Videos", bundle: .module)
        case .image: String(localized: "Images", bundle: .module)
        }
    }
}

/// One row of the unified library grid: a video result, an image made on this Mac, or an image still only on
/// the Higgsfield account. Videos and images share the grid, the search and the sort; each kind keeps its own
/// filters, and a filter that doesn't apply to the current kind is hidden rather than left without effect.
public enum LibraryMediaItem: Sendable, Hashable, Identifiable {
    case video(LibraryItemModel)
    /// An image Generate… made, saved in the output folder.
    case localImage(SavedImage)
    /// A finished image generation from the account's history; its file downloads on demand.
    case remoteImage(HistoryImageItem)

    public var id: UUID {
        switch self {
        case .video(let item): item.id
        case .localImage(let image): image.id
        case .remoteImage(let image): image.jobID
        }
    }

    public var isVideo: Bool {
        switch self {
        case .video: true
        case .localImage, .remoteImage: false
        }
    }

    /// Newest first in the grid: when a video finished for videos, when an image was made for images.
    public var createdAt: Date {
        switch self {
        case .video(let item): item.finishedAt
        case .localImage(let image): image.createdAt
        case .remoteImage(let image): image.createdAt
        }
    }

    /// Starred here, or liked on Higgsfield: the star and the like are one.
    public var isStarred: Bool {
        switch self {
        case .video(let item): item.isStarred
        case .localImage(let image): image.isStarred
        case .remoteImage(let image): image.isLiked
        }
    }

    /// What the search looks through: the prompt and the model for images, the video's own text for videos.
    public var searchText: String {
        switch self {
        case .video(let item): "\(item.spec.prompt) \(item.title)"
        case .localImage(let image): "\(image.prompt) \(image.model)"
        case .remoteImage(let image): "\(image.prompt) \(image.model)"
        }
    }

    /// The model menu value: the video model for videos, the image model's name for images.
    public var imageModel: String? {
        switch self {
        case .video: nil
        case .localImage(let image): image.model
        case .remoteImage(let image): image.model
        }
    }

    /// "16:9" for images; `nil` for videos and when unknown.
    public var aspectRatio: String? {
        switch self {
        case .video: nil
        // Saved before labels were rounded, a stored ratio can still be "73:55".
        case .localImage(let image): image.aspectRatio.map(PixelSize.aspectLabel(of:))
        case .remoteImage(let image): image.aspectRatio
        }
    }
}

/// One card of the unified grid: a video entry (a result, or a batch of results), or an image.
public enum LibraryGridRow: Sendable, Hashable, Identifiable {
    case entry(LibraryEntry)
    case image(LibraryMediaItem)

    public var id: UUID {
        switch self {
        case .entry(let entry): entry.id
        case .image(let image): image.id
        }
    }

    /// Newest first in the grid: the entry's newest result, or when the image was made.
    public var createdAt: Date {
        switch self {
        case .entry(let entry): entry.newestDate
        case .image(let image): image.createdAt
        }
    }
}

/// The unified grid's cards: video entries and images in one order.
public enum LibraryMediaGrid {
    /// Entries and images interleaved by date for Newest/Oldest; for Highest price the entries keep their price
    /// order and the images, which have no price, follow. `entries` come grouped, `images` filtered; both in
    /// any order, since a batch sits at its first member, not at its newest result.
    public static func arrange(
        entries: [LibraryEntry], images: [LibraryMediaItem], sort: LibraryFilter.Sort
    ) -> [LibraryGridRow] {
        guard sort != .highestPrice else {
            return entries.map(LibraryGridRow.entry) + images.map(LibraryGridRow.image)
        }
        let ascending = sort == .oldest
        var restEntries = entries.sorted {
            ascending ? $0.newestDate < $1.newestDate : $0.newestDate > $1.newestDate
        }
        var restImages = images.sorted {
            ascending ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt
        }
        var rows: [LibraryGridRow] = []
        while !restEntries.isEmpty || !restImages.isEmpty {
            switch (restEntries.first, restImages.first) {
            case (nil, nil):
                break
            case (nil, _):
                rows.append(.image(restImages.removeFirst()))
            case (_, nil):
                rows.append(.entry(restEntries.removeFirst()))
            case (let entry?, let image?):
                let entryFirst =
                    ascending ? entry.newestDate <= image.createdAt : entry.newestDate >= image.createdAt
                rows.append(entryFirst ? .entry(restEntries.removeFirst()) : .image(restImages.removeFirst()))
            }
        }
        return rows
    }
}
/// How many rows each kind tab holds, after every filter but the kind itself: the tabs always match the grid.
public struct LibraryKindCounts: Sendable, Hashable {
    public var videos: Int
    public var images: Int

    public init(videos: Int, images: Int) {
        self.videos = videos
        self.images = images
    }

    public var all: Int { videos + images }

    public func count(for kind: LibraryKind) -> Int {
        switch kind {
        case .all: all
        case .video: videos
        case .image: images
        }
    }
}

/// Which of the grid's rows ⌘A and the menus act on: only the current kind's visible rows, so Select All in
/// Images never picks videos, and the video menus never see a hidden selection.
public enum LibraryKindSelection {
    /// The video entries ⌘A picks and the video menus act on; none with Images.
    public static func entries(for kind: LibraryKind, in rows: [LibraryGridRow]) -> [LibraryEntry] {
        guard kind != .image else { return [] }
        return rows.compactMap {
            guard case .entry(let entry) = $0 else { return nil }
            return entry
        }
    }

    /// The image IDs ⌘A picks; none with Videos.
    public static func imageIDs(for kind: LibraryKind, in rows: [LibraryGridRow]) -> Set<UUID> {
        guard kind != .video else { return [] }
        return Set(
            rows.compactMap {
                guard case .image(let media) = $0 else { return nil }
                return media.id
            })
    }

    /// The videos the selection, menus and deletion operate on: only the visible ones, none with Images.
    public static func videos(for kind: LibraryKind, in videos: [LibraryItemModel]) -> [LibraryItemModel] {
        kind == .image ? [] : videos
    }
}
