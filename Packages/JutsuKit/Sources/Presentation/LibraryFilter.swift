import Foundation
import JutsuCore

/// The library toolbar: search over prompt and title, mode, model, resolution, draft/final and starred filters,
/// and the order of the grid. Mode, model, resolution and draft/final apply to videos only; image model and
/// aspect ratio to images only; search, starred and sort to both.
public struct LibraryFilter: Sendable, Hashable {
    /// Draft or final: videos only, so hidden with kind Images.
    public enum Finish: String, Sendable, Hashable, CaseIterable, Identifiable {
        case all
        case drafts
        case finals

        public var id: Self { self }
        public var title: String {
            switch self {
            case .all: String(localized: "All", bundle: .module)
            case .drafts: String(localized: "Drafts", bundle: .module)
            case .finals: String(localized: "Finals", bundle: .module)
            }
        }
    }

    /// One control of the filter bar, in bar order. Search, starred and sort show for every kind; the rest only
    /// where they can change the grid.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case mode
        case model
        case resolution
        case finish
        case imageModel
        case imageAspectRatio
        case starred
        case rejected
        case sort

        /// The fields the bar shows for `kind`: video-only filters hide with Images, image-only filters hide
        /// with Videos, and with All everything shows, each constraining its own media.
        public static func visible(for kind: LibraryKind) -> [Field] {
            switch kind {
            case .all:
                [.mode, .model, .resolution, .finish, .imageModel, .imageAspectRatio, .starred, .rejected, .sort]
            case .video: [.mode, .model, .resolution, .finish, .starred, .rejected, .sort]
            case .image: [.imageModel, .imageAspectRatio, .starred, .rejected, .sort]
            }
        }
    }

    public enum Sort: String, Sendable, Hashable, CaseIterable, Identifiable {
        case newest
        case oldest
        /// Dollars before credits, which can't be compared with them, the most expensive first; a video made on
        /// Higgsfield, whose price isn't known, last.
        case highestPrice

        public var id: Self { self }
        public var title: String {
            switch self {
            case .newest: String(localized: "Newest first", bundle: .module)
            case .oldest: String(localized: "Oldest first", bundle: .module)
            case .highestPrice: String(localized: "Highest price", bundle: .module)
            }
        }
    }

    public var query: String
    /// `nil` for every mode.
    public var mode: Mode?
    /// `nil` for every video model.
    public var model: VideoModel?
    /// `nil` for every resolution.
    public var resolution: Resolution?
    public var finish: Finish
    /// `nil` for every image model, by name.
    public var imageModel: String?
    /// `nil` for every aspect ratio, e.g. "16:9".
    public var imageAspectRatio: String?
    /// Starred here, or liked on Higgsfield: the star and the like are one.
    public var isStarredOnly: Bool
    /// Rejected results stay out of every tab and every search until this is on.
    public var showsRejected: Bool
    public var sort: Sort

    public init(
        query: String = "", mode: Mode? = nil, model: VideoModel? = nil, resolution: Resolution? = nil,
        finish: Finish = .all, imageModel: String? = nil, imageAspectRatio: String? = nil,
        isStarredOnly: Bool = false, showsRejected: Bool = false, sort: Sort = .newest
    ) {
        self.query = query
        self.mode = mode
        self.model = model
        self.resolution = resolution
        self.finish = finish
        self.imageModel = imageModel
        self.imageAspectRatio = imageAspectRatio
        self.isStarredOnly = isStarredOnly
        self.showsRejected = showsRejected
        self.sort = sort
    }

    public func matches(_ item: LibraryItemModel) -> Bool {
        let spec = item.spec
        if isStarredOnly, !item.isStarred { return false }
        if let mode, spec.mode != mode { return false }
        if let model, spec.model != model { return false }
        if let resolution, spec.resolution != resolution { return false }
        if finish != .all, spec.isDraft != (finish == .drafts) { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return "\(spec.prompt) \(item.title)".lowercased().contains(needle)
    }

    /// Whether an image row shows: the search matches every word against its prompt and model, like the Images
    /// page did; video filters never touch images.
    public func matches(image: LibraryMediaItem) -> Bool {
        if isStarredOnly, !image.isStarred { return false }
        if let imageModel, image.imageModel != imageModel { return false }
        if let imageAspectRatio, image.aspectRatio != imageAspectRatio { return false }
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let text = image.searchText.lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// Whether a grid row shows, before the kind tab picks its media: each filter constrains its own media.
    public func matches(_ row: LibraryMediaItem) -> Bool {
        switch row {
        case .video(let item): matches(item)
        case .localImage, .remoteImage: matches(image: row)
        }
    }

    /// The matching videos in `sort` order, for callers without images in the grid. `items` come newest first,
    /// which `.newest` keeps.
    public func apply(_ items: [LibraryItemModel]) -> [LibraryItemModel] {
        let matching = items.filter(matches)
        switch sort {
        case .newest:
            return matching
        case .oldest:
            return matching.reversed()
        case .highestPrice:
            // Ties keep their place, so equal prices stay newest first.
            return matching.enumerated()
                .sorted { lhs, rhs in
                    let left = Self.priceKey(lhs.element)
                    let right = Self.priceKey(rhs.element)
                    if left.rank != right.rank { return left.rank < right.rank }
                    if left.amount != right.amount { return left.amount > right.amount }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        }
    }

    /// The matching rows of `kind` in `sort` order. With All, videos and images interleave by date; video
    /// filters never touch images, image filters never touch videos.
    public func apply(_ rows: [LibraryMediaItem], kind: LibraryKind) -> [LibraryMediaItem] {
        let matching = rows.filter { self.matches($0) }.filter { kind == .all || $0.isVideo == (kind == .video) }
        switch sort {
        case .newest:
            return matching.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return matching.sorted { $0.createdAt < $1.createdAt }
        case .highestPrice:
            // Ties keep their place, so equal prices stay newest first; images, which have no price, go last.
            return matching.enumerated()
                .sorted { lhs, rhs in
                    let left = Self.priceKey(lhs.element)
                    let right = Self.priceKey(rhs.element)
                    if left.rank != right.rank { return left.rank < right.rank }
                    if left.amount != right.amount { return left.amount > right.amount }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        }
    }

    /// `rows` without the rejected ones unless they are shown. Runs before the search, the other filters and the
    /// tabs' counts, so nothing brings a rejected result back silently.
    public func culled(_ rows: [LibraryMediaItem], index: LibraryCatalogIndex) -> [LibraryMediaItem] {
        showsRejected ? rows : rows.filter { !index.isRejected($0.id) }
    }

    /// The kind tabs' counts over `rows`: every filter but the kind itself applies, so the tabs match the grid.
    public func counts(_ rows: [LibraryMediaItem]) -> LibraryKindCounts {
        let matching = rows.filter { self.matches($0) }
        return LibraryKindCounts(
            videos: matching.filter(\.isVideo).count, images: matching.filter { !$0.isVideo }.count)
    }

    private static func priceKey(_ row: LibraryMediaItem) -> (rank: Int, amount: Decimal) {
        guard case .video(let item) = row, !item.isFromHiggsfield else { return (2, 0) }
        let price = item.job.price
        return (price.unit == .usd ? 0 : 1, price.amount)
    }

    private static func priceKey(_ item: LibraryItemModel) -> (rank: Int, amount: Decimal) {
        guard !item.isFromHiggsfield else { return (2, 0) }
        let price = item.job.price
        return (price.unit == .usd ? 0 : 1, price.amount)
    }

    /// Whether search or a filter hides anything; the order, and showing rejected results, don't count.
    public var isActive: Bool {
        var unsorted = self
        unsorted.sort = .newest
        unsorted.showsRejected = false
        return unsorted != LibraryFilter()
    }

    /// The same order with every filter and the search cleared, so a result the filters hid can be shown.
    public var cleared: LibraryFilter { LibraryFilter(sort: sort) }
}
