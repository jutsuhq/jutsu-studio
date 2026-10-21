import Foundation
import JutsuCore

/// `library_search`: the Library's own rows and filters (`MaterialLibrary.row`, `LibraryFilter`) over the catalog,
/// read-only. Only results with a file on this Mac are listed, since an agent works with paths; rejected ones only
/// when asked for.
public struct AgentLibraryQuery: Sendable, Hashable {
    public var text: String
    public var kind: LibraryKind
    /// `nil` for both.
    // swiftlint:disable:next discouraged_optional_boolean
    public var starred: Bool?
    /// `nil` for every verdict but rejected, unless `includeRejected`.
    public var verdict: Culling?
    public var includeRejected: Bool
    /// A video model ID ("seedance25") or an image model's name; `nil` for every model.
    public var model: String?
    /// A video mode; images have none, so a mode lists videos only.
    public var mode: Mode?
    public var from: Date?
    public var to: Date?
    public var limit: Int
    public var cursor: String?

    public init(
        // swiftlint:disable:next discouraged_optional_boolean
        text: String = "", kind: LibraryKind = .all, starred: Bool? = nil, verdict: Culling? = nil,
        includeRejected: Bool = false, model: String? = nil, mode: Mode? = nil, from: Date? = nil, to: Date? = nil,
        limit: Int = 20, cursor: String? = nil
    ) {
        self.text = text
        self.kind = kind
        self.starred = starred
        self.verdict = verdict
        self.includeRejected = includeRejected
        self.model = model
        self.mode = mode
        self.from = from
        self.to = to
        self.limit = limit
        self.cursor = cursor
    }
}

/// One result as an agent sees it, before the wire's names.
public struct AgentLibraryHit: Sendable, Hashable {
    public var id: UUID
    public var isVideo: Bool
    public var file: URL
    /// A video model's ID, or an image model's name.
    public var model: String
    /// The agent's mode name; `nil` for an image.
    public var mode: String?
    public var aspectRatio: String?
    public var duration: TimeInterval?
    public var price: Cost?
    public var culling: Culling
    public var isStarred: Bool
    public var createdAt: Date
    public var prompt: String
    public var isPromptTruncated: Bool
    public var versionID: UUID
    /// Which version is current, from 1.
    public var version: Int
    public var versionCount: Int
    /// The job that made a video; `nil` for an image.
    public var jobID: UUID?
}

public enum AgentLibrarySearch {
    public static let promptLength = 200

    /// The page of `materials` that `query` asks for, newest first, and the cursor of the next one.
    public static func page(
        _ materials: [Material], _ query: AgentLibraryQuery
    ) -> (hits: [AgentLibraryHit], next: String?) {
        let index = LibraryCatalogIndex(materials)
        let byID = Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = materials.compactMap(MaterialLibrary.row).filter(\.isLocal)
        let filter = LibraryFilter(
            query: query.text, isStarredOnly: query.starred == true,
            showsRejected: query.includeRejected || query.verdict == .rejected, sort: .newest)
        let matching = filter.apply(filter.culled(rows, index: index), kind: query.kind).filter { row in
            guard let material = byID[row.id] else { return false }
            return matches(row, material: material, culling: index.culling(of: row.id), query: query)
        }
        let hits = matching.compactMap { row in byID[row.id].flatMap { hit(row, material: $0, index: index) } }
            .sorted { AgentCursor.isNewerFirst(($0.createdAt, $0.id), ($1.createdAt, $1.id)) }
        let rest =
            query.cursor.flatMap(AgentCursor.init(text:)).map { position in
                hits.filter { position.precedes($0.createdAt, $0.id) }
            } ?? hits
        let page = Array(rest.prefix(max(1, query.limit)))
        let next = rest.count > page.count ? page.last.map { AgentCursor($0.createdAt, $0.id).text } : nil
        return (page, next)
    }

    private static func matches(
        _ row: LibraryMediaItem, material: Material, culling: Culling, query: AgentLibraryQuery
    ) -> Bool {
        if query.starred == false, row.isStarred { return false }
        if let verdict = query.verdict, culling != verdict { return false }
        if let from = query.from, row.createdAt < from { return false }
        if let to = query.to, row.createdAt > to { return false }
        switch row {
        case .video(let item):
            if let mode = query.mode, item.spec.mode != mode { return false }
            if let model = query.model, item.spec.model.rawValue != model { return false }
        case .localImage(let image):
            if query.mode != nil { return false }
            if let model = query.model, image.model != model { return false }
        case .remoteImage:
            return false
        }
        return true
    }

    private static func hit(_ row: LibraryMediaItem, material: Material, index: LibraryCatalogIndex) -> AgentLibraryHit?
    {
        let version = material.current
        let position = (material.versions.firstIndex { $0.id == version.id } ?? 0) + 1
        let (prompt, isTruncated) = truncated(version.generation?.prompt ?? "")
        switch row {
        case .video(let item):
            guard let file = item.outputFile else { return nil }
            let prompt = truncated(item.spec.prompt)
            return AgentLibraryHit(
                id: material.id, isVideo: true, file: file, model: item.spec.model.rawValue,
                mode: AgentVideoOrder.name(of: item.spec.mode),
                aspectRatio: item.spec.aspectRatio?.rawValue ?? version.aspectRatio,
                duration: item.job.outputDuration, price: item.isFromHiggsfield ? nil : item.job.price,
                culling: index.culling(of: material.id), isStarred: item.isStarred, createdAt: row.createdAt,
                prompt: prompt.text, isPromptTruncated: prompt.isTruncated, versionID: version.id, version: position,
                versionCount: material.versions.count, jobID: item.job.id)
        case .localImage(let image):
            return AgentLibraryHit(
                id: material.id, isVideo: false, file: image.fileURL, model: image.model, mode: nil,
                aspectRatio: image.aspectRatio, duration: nil, price: nil, culling: index.culling(of: material.id),
                isStarred: image.isStarred, createdAt: row.createdAt, prompt: prompt, isPromptTruncated: isTruncated,
                versionID: version.id, version: position, versionCount: material.versions.count, jobID: nil)
        case .remoteImage:
            return nil
        }
    }

    /// The first `promptLength` characters, and whether there were more.
    static func truncated(_ prompt: String) -> (text: String, isTruncated: Bool) {
        guard prompt.count > promptLength else { return (prompt, false) }
        return (String(prompt.prefix(promptLength)), true)
    }
}

extension LibraryMediaItem {
    /// It has a file on this Mac: what an agent's Library commands act on.
    public var isLocal: Bool {
        switch self {
        case .video(let item): item.historyItem == nil && item.outputFile != nil
        case .localImage: true
        case .remoteImage: false
        }
    }
}

/// `library_mark`: what Keep, Reject or Clear and the star change for the results named, worked out as the Library
/// does it (`CullingHistory.apply`, one star per result) before anything is written. Marking the same way again
/// changes nothing; nothing here hides a file or deletes one.
public struct AgentLibraryMarks: Sendable, Hashable {
    /// The culling to write; empty when every result has the verdict already.
    public var culling: [MaterialReference: Culling]
    /// The videos whose star changes, as the Library's star takes them.
    public var videos: [LibraryItemModel]
    /// The saved images whose star changes.
    public var images: Set<UUID>
    public struct Marked: Sendable, Hashable {
        public var id: UUID
        public var culling: Culling
        public var isStarred: Bool
    }

    /// Each result as it is once the changes are written, in the order asked.
    public var results: [Marked]
    /// IDs that aren't results with a file on this Mac: nothing is changed when there are any.
    public var missing: [UUID]

    public var changes: Int { culling.count + videos.count + images.count }

    // swiftlint:disable:next discouraged_optional_boolean
    public init(ids: [UUID], verdict: CullingAction?, star: Bool?, materials: [Material]) {
        let index = LibraryCatalogIndex(materials)
        let rows = Dictionary(
            materials.compactMap(MaterialLibrary.row).filter(\.isLocal).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        missing = ids.filter { rows[$0] == nil }
        var history = CullingHistory()
        culling = missing.isEmpty ? (verdict.flatMap { history.apply($0, to: ids, in: index) } ?? [:]) : [:]
        var videos: [LibraryItemModel] = []
        var images: Set<UUID> = []
        var results: [Marked] = []
        for id in ids {
            guard let row = rows[id] else { continue }
            let isStarred = star ?? row.isStarred
            if missing.isEmpty, isStarred != row.isStarred {
                switch row {
                case .video(let item): videos.append(item)
                case .localImage: images.insert(id)
                case .remoteImage: break
                }
            }
            results.append(Marked(id: id, culling: verdict?.result ?? index.culling(of: id), isStarred: isStarred))
        }
        self.videos = videos
        self.images = images
        self.results = results
    }
}
