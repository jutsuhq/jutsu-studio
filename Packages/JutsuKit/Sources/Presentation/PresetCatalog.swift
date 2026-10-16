import Foundation
import JutsuCore
import Observation

/// The restyle presets: the cached catalog first, replaced by the provider's list on every refresh.
@MainActor
@Observable
public final class PresetCatalog {
    public nonisolated static let cacheFileName = "catalog.json"

    public private(set) var presets: [StylePreset] = []
    public private(set) var isRefreshing = false
    /// The last refresh failed; the cached list is still shown.
    public private(set) var refreshFailure: UserMessage?
    public var query = ""

    @ObservationIgnored private let cacheFolder: URL

    public init(cacheFolder: URL) {
        self.cacheFolder = cacheFolder
    }

    private var cacheFile: URL { cacheFolder.appendingPathComponent(Self.cacheFileName) }

    /// Presets whose name contains the query, ignoring case and accents.
    public var filtered: [StylePreset] {
        presets.filter { PresetShelf.matches($0.name, query: query) }
    }

    public func preset(id: UUID?) -> StylePreset? {
        presets.first { $0.id == id }
    }

    /// Shows the cached catalog until a refresh replaces it; the file is read off the main actor.
    /// A missing or unreadable cache is ignored, and so is the cache once presets are shown.
    public func loadCache() async {
        guard presets.isEmpty else { return }
        let cached = await Self.readCache(in: cacheFolder)
        guard presets.isEmpty, let cached else { return }
        presets = cached
    }

    /// A preset's name from the cached catalog, off the main actor; `nil` when it isn't cached.
    public nonisolated static func cachedName(of id: UUID, in cacheFolder: URL) -> String? {
        cachedPreset(id: id, in: cacheFolder)?.name
    }

    /// A preset from the cached catalog, off the main actor; `nil` when it isn't cached.
    public nonisolated static func cachedPreset(id: UUID, in cacheFolder: URL) -> StylePreset? {
        cachedPresets(in: cacheFolder)?.first { $0.id == id }
    }

    /// Async and nonisolated, so the caller's actor isn't blocked by the read.
    private nonisolated static func readCache(in cacheFolder: URL) async -> [StylePreset]? {
        cachedPresets(in: cacheFolder)
    }

    private nonisolated static func cachedPresets(in cacheFolder: URL) -> [StylePreset]? {
        guard let data = try? Data(contentsOf: cacheFolder.appendingPathComponent(cacheFileName)) else { return nil }
        return try? JSONDecoder().decode([StylePreset].self, from: data)
    }

    /// Fetches the catalog and caches it. Ignored while a refresh is running.
    public func refresh(_ fetch: @Sendable () async throws -> [StylePreset]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await fetch()
            presets = fresh
            refreshFailure = nil
            try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(fresh).write(to: cacheFile, options: .atomic)
        } catch {
            refreshFailure = UserMessage(error)
        }
    }
}
