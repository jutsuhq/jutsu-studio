import Foundation
import JutsuCore

/// One video on a compare surface: a result, or the source it was made from, with the chips that label it.
public struct CompareTrack: Sendable, Hashable, Identifiable {
    public struct ID: Sendable, Hashable {
        public var itemID: UUID
        public var side: PlaybackSide

        public init(itemID: UUID, side: PlaybackSide) {
            self.itemID = itemID
            self.side = side
        }
    }

    public var id: ID
    public var clip: PlaybackClip
    public var labels: [String]

    public init(id: ID, clip: PlaybackClip, labels: [String]) {
        self.id = id
        self.clip = clip
        self.labels = labels
    }

    /// The item's result, labelled with its settings chips; `nil` without a local file.
    public static func result(_ item: LibraryItemModel) -> CompareTrack? {
        item.playback(.result).map {
            CompareTrack(id: ID(itemID: item.id, side: .result), clip: $0, labels: item.facts)
        }
    }

    /// The range of the original the item was made from; `nil` unless it is a local file. `labels` defaults to
    /// "Source".
    public static func source(_ item: LibraryItemModel, labels: [String]? = nil) -> CompareTrack? {
        let labels = labels ?? [String(localized: "Source", bundle: .module)]
        return item.playback(.source).map {
            CompareTrack(id: ID(itemID: item.id, side: .source), clip: $0, labels: labels)
        }
    }

    /// A source follows the results through its range and holds at its end; it doesn't bound the shared clock.
    public var isSource: Bool { id.side == .source }
}

/// How the compare surface shows its videos.
public enum CompareLayout: String, CaseIterable, Sendable, Hashable {
    case sideBySide
    case divider

    public var title: String {
        switch self {
        case .sideBySide: String(localized: "Side by side", bundle: .module)
        case .divider: String(localized: "Divider", bundle: .module)
        }
    }

    /// The divider lays one video over another, so it takes exactly two.
    public static func available(forTrackCount count: Int) -> [CompareLayout] {
        count == 2 ? allCases : [.sideBySide]
    }

    /// Columns of the side-by-side grid: one row up to three videos, then as square as it gets.
    public static func columns(forTrackCount count: Int) -> Int {
        guard count > 3 else { return max(count, 1) }
        return Int(Double(count).squareRoot().rounded(.up))
    }
}

/// The one clock every video on a compare surface follows. Time is in seconds, so clips of different
/// frame rates stay in step; each shows its frame nearest to the shared time.
public enum CompareTimeline {
    /// The shared clock stops at the shortest result; a duration not known yet is skipped. 0 while none is known.
    public static func duration(of resultDurations: [TimeInterval?]) -> TimeInterval {
        resultDurations.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }.min() ?? 0
    }
}

/// Two library results compared on one page: which plays on the left, which on the right.
public struct ComparePair: Sendable, Hashable {
    public private(set) var left: LibraryItemModel
    public private(set) var right: LibraryItemModel
    /// Chips put before a side's own, by item: "Original" and "New version" for two versions of one item.
    public private(set) var labels: [UUID: [String]] = [:]

    public static let originalLabel = String(localized: "Original", bundle: .module)
    public static let editedLabel = String(localized: "New version", bundle: .module)

    /// `nil` for the same item twice or a result without a local file.
    public init?(_ left: LibraryItemModel, _ right: LibraryItemModel) {
        guard left.id != right.id, left.outputFile != nil, right.outputFile != nil else { return nil }
        self.left = left
        self.right = right
    }

    /// Two versions of one item: the one it was made from on the left (`MaterialVersions.videoPair`).
    public init?(original: LibraryItemModel, edited: LibraryItemModel) {
        self.init(original, edited)
        labels = [original.id: [Self.originalLabel], edited.id: [Self.editedLabel]]
    }

    public mutating func swap() {
        (left, right) = (right, left)
    }

    /// Left first.
    public var tracks: [CompareTrack] {
        [left, right].compactMap { item in
            CompareTrack.result(item).map { track in
                var track = track
                track.labels = (labels[item.id] ?? []) + track.labels
                return track
            }
        }
    }

    /// What "Compare with…" offers for `item`: other results on disk, those made from the same source first,
    /// otherwise in the library's order. At most `limit`, so the menu stays short.
    public static func candidates(
        for item: LibraryItemModel, in items: [LibraryItemModel], limit: Int = 12
    ) -> [LibraryItemModel] {
        let others = items.filter { $0.id != item.id && $0.outputFile != nil }
        let source = item.spec.source?.fileURL
        let sameSource = others.filter { source != nil && $0.spec.source?.fileURL == source }
        let rest = others.filter { source == nil || $0.spec.source?.fileURL != source }
        return Array((sameSource + rest).prefix(max(limit, 0)))
    }

    /// "rooftop · Claymation — 480p draft", a "Compare with…" menu item.
    public static func menuTitle(for item: LibraryItemModel) -> String {
        let resolution = item.spec.resolutionTitle
        return item.spec.isDraft
            ? String(localized: "\(item.title) — \(resolution) draft", bundle: .module)
            : String(localized: "\(item.title) — \(resolution) final", bundle: .module)
    }
}

/// One image on the compare surface: a saved file, or an account image downloaded first. Videos keep their
/// own compare; images share zoom and pan instead of a clock.
public struct CompareImage: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var fileURL: URL
    public var prompt: String

    public init(id: UUID, fileURL: URL, prompt: String) {
        self.id = id
        self.fileURL = fileURL
        self.prompt = prompt
    }

    public static func saved(_ image: SavedImage) -> CompareImage {
        CompareImage(id: image.id, fileURL: image.fileURL, prompt: image.prompt)
    }
}

/// Two images compared side by side at the same zoom; `nil` for the same image twice.
public struct ImageComparePair: Sendable, Hashable {
    public private(set) var left: CompareImage
    public private(set) var right: CompareImage

    public init?(_ left: CompareImage, _ right: CompareImage) {
        guard left.id != right.id else { return nil }
        self.left = left
        self.right = right
    }

    public mutating func swap() {
        (left, right) = (right, left)
    }
}

/// A variant group in the image compare: one variant stays on the left while the right side steps through the
/// others, so a group is judged two at a time without going back to the grid.
public struct VariantCompare: Sendable, Hashable {
    public let variants: [CompareImage]
    public private(set) var left: Int
    public private(set) var right: Int

    /// `nil` with fewer than two variants.
    public init?(_ variants: [CompareImage]) {
        guard variants.count > 1 else { return nil }
        self.variants = variants
        left = 0
        right = 1
    }

    public var pair: ImageComparePair? { ImageComparePair(variants[left], variants[right]) }

    /// Moves the right side `offset` variants on, wrapping around and skipping the left side's.
    public mutating func step(_ offset: Int) {
        for _ in 0..<abs(offset) {
            repeat {
                right = ((right + offset.signum()) % variants.count + variants.count) % variants.count
            } while right == left
        }
    }

    public mutating func swap() {
        (left, right) = (right, left)
    }

    /// "Variant 2 of 4", the right side's place in the group.
    public var position: String {
        String(localized: "Variant \(right + 1) of \(variants.count)", bundle: .module)
    }
}

/// The zoom and pan both images of a compare follow. One state drives both panes, so they stay in step; each
/// pane shows the same magnification around its own center, panning together from there.
public struct ImageCompareState: Sendable, Hashable {
    /// How many image pixels a point shows: 1 is actual size.
    public var zoom: Double
    /// Points panned from the centered image, at the current zoom.
    public var offsetX: Double
    public var offsetY: Double
    /// Whether each pane fits its image (`true`) or shows actual pixels with panning (`false`).
    public var fitsPane: Bool

    public static let minZoom = 0.1
    public static let maxZoom = 8.0

    public init(zoom: Double = 1, offsetX: Double = 0, offsetY: Double = 0, fitsPane: Bool = true) {
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.fitsPane = fitsPane
    }

    /// Actual size, centered: one image pixel per point, so different sizes compare at the same magnification.
    public mutating func showActualSize() {
        zoom = 1
        offsetX = 0
        offsetY = 0
        fitsPane = false
    }

    /// Fit each image into its pane, centered.
    public mutating func showFit() {
        zoom = 1
        offsetX = 0
        offsetY = 0
        fitsPane = true
    }

    /// How an image of `imageWidth`×`imageHeight` scales to fit a pane, never magnifying past actual size.
    public static func fitScale(
        imageWidth: Double, imageHeight: Double, paneWidth: Double, paneHeight: Double
    ) -> Double {
        guard imageWidth > 0, imageHeight > 0, paneWidth > 0, paneHeight > 0 else { return 1 }
        return min(paneWidth / imageWidth, paneHeight / imageHeight, 1)
    }

    /// The scale a pane draws its image at: the fit scale magnified while fitting, actual pixels magnified
    /// otherwise. Zoom 1 in actual size is 1:1, whatever the pane holds.
    public func displayScale(fitScale: Double) -> Double {
        fitsPane ? fitScale * zoom : zoom
    }

    public mutating func setZoom(_ zoom: Double) {
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    public mutating func pan(byX dx: Double, y dy: Double) {
        offsetX += dx
        offsetY += dy
    }
}

/// Picking two results in the Library grid to compare. A third pick replaces the oldest.
public struct ComparePicker: Sendable, Hashable {
    public private(set) var picked: [UUID] = []

    public init() {}

    public mutating func toggle(_ id: UUID) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
            return
        }
        picked.append(id)
        if picked.count > 2 { picked.removeFirst(picked.count - 2) }
    }

    public func isPicked(_ id: UUID) -> Bool { picked.contains(id) }

    /// The two picks in the order they were picked; `nil` until both are in `items` with a file.
    public func pair(in items: [LibraryItemModel]) -> ComparePair? {
        guard picked.count == 2,
            let first = items.first(where: { $0.id == picked[0] }),
            let second = items.first(where: { $0.id == picked[1] })
        else { return nil }
        return ComparePair(first, second)
    }

    public var prompt: String {
        switch picked.count {
        case 0: String(localized: "Pick two results to compare", bundle: .module)
        case 1: String(localized: "Pick one more", bundle: .module)
        default: String(localized: "Ready to compare", bundle: .module)
        }
    }
}
