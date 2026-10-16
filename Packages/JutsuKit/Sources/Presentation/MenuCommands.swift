import Foundation
import JutsuCore

/// A command on one job. A Queue row's buttons, the Queue menu and the job's notification run the same ones.
public enum JobCommand: Sendable, Hashable {
    case cancel
    /// Sends a job that was never charged again, or downloads the paid result of one again.
    case retry
    /// Polls a job past its deadline again.
    case checkAgain
    case resume
    case runNext
}

/// What the Queue menu's job items do with the selected job, by the rules of its row's buttons.
public struct QueueJobCommands: Sendable, Hashable {
    /// The row offers Cancel and the job can still be canceled.
    public var canCancel: Bool
    /// What Retry runs; `nil` when the row offers neither Retry, Retry download nor Check again.
    public var retry: JobCommand?
    /// The Retry item's title, named after the row's button it stands for.
    public var retryTitle: String

    public init(_ row: JobRowModel) {
        canCancel = row.actions.contains { action in
            if case .cancel(isEnabled: true, _) = action { true } else { false }
        }
        if row.actions.contains(.retryDownload) {
            (retry, retryTitle) = (.retry, String(localized: "Retry Download", bundle: .module))
        } else if row.actions.contains(.checkAgain) {
            (retry, retryTitle) = (.checkAgain, String(localized: "Check Again", bundle: .module))
        } else {
            retry = row.actions.contains(.retry) ? .retry : nil
            retryTitle = String(localized: "Retry Job", bundle: .module)
        }
    }

    public init(_ job: Job, now: Date = .now) {
        self.init(JobRowModel(job, now: now))
    }
}

/// What the Library menu acts on: the result whose page is open, or else the results selected in the grid.
public struct LibraryMenuTargets: Sendable, Hashable {
    /// The results whose star can change here.
    public var starrable: [LibraryItemModel]
    /// Star stars them all unless every one is starred; then it unstars them.
    public var starsAll: Bool
    public var deletable: [LibraryItemModel]
    /// The one result whose final Render Final makes; `nil` for none or several, or for a result still only on
    /// Higgsfield, whose final is made from Edit Inputs instead.
    public var renderFinal: LibraryItemModel?

    /// - Parameter canStar: whether a result's star can change here (a local result, or a like Higgsfield syncs).
    public init(_ items: [LibraryItemModel], canStar: (LibraryItemModel) -> Bool) {
        starrable = items.filter(canStar)
        starsAll = LibraryBulkActions.starsAll(starrable)
        deletable = LibraryBulkActions(items).deletable
        let only = items.count == 1 ? items.first : nil
        renderFinal = only.flatMap { $0.canRenderFinal && $0.historyItem == nil ? $0 : nil }
    }

    public var starTitle: String {
        starsAll ? String(localized: "Star", bundle: .module) : String(localized: "Unstar", bundle: .module)
    }
}

/// What ⌘V in Create takes from the clipboard.
public enum PastedInput: Sendable, Hashable {
    /// Files copied in Finder; they go where opened files go: a video to the source, images to the references.
    case files([URL])
    /// Image data, such as a screenshot or an image copied in a browser; it is saved to a file first.
    case image
    /// An `https:` link copied as text or as a URL; it is downloaded first (`MediaLink`).
    case link(URL)

    /// `nil` when the clipboard holds none of these. Files win over image data: Finder copies their icons as an image
    /// too. Image data wins over a link: a browser's Copy Image puts the image's address next to it.
    /// - Parameters:
    ///   - links: web URLs on the clipboard; only an `https:` one is taken.
    ///   - text: the clipboard's text, taken when it is one `https:` link and nothing else.
    public init?(fileURLs: [URL], hasImage: Bool, links: [URL] = [], text: String? = nil) {
        let files = fileURLs.filter(\.isFileURL)
        if !files.isEmpty {
            self = .files(files)
        } else if hasImage {
            self = .image
        } else if let link = links.lazy.compactMap({ try? MediaLink.parse($0.absoluteString) }).first
            ?? text.flatMap({ try? MediaLink.parse($0) })
        {
            self = .link(link)
        } else {
            return nil
        }
    }
}
