import Foundation
import JutsuCore

/// Where an agent's `delivery_set` and `export` write, and under which names: the Library's own plans
/// (`DeliveryPlan`, `ExportNaming`), with one rule more. An agent never writes over a file, not even one a delivery set
/// wrote before: such a file gets a new name beside it.
public enum AgentExports {
    /// The names already in `folder`, lowercased, as the usual case-insensitive volumes compare them; none for a
    /// folder that isn't there yet.
    public static func existingNames(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return Set(names.map { $0.lowercased() })
    }

    /// The folders the person exported delivery sets to, newest export first, each once.
    public static func folders(of sets: [DeliverySet]) -> [DeliverySet.Folder] {
        var seen: Set<String> = []
        return sets.filter { $0.folder != nil }
            .sorted { ($0.exportedAt ?? .distantPast) > ($1.exportedAt ?? .distantPast) }
            .compactMap(\.folder)
            .filter { seen.insert(path($0.url)).inserted }
    }

    /// `path` when the person already exported a set there; `nil` for any other folder.
    public static func knownFolder(_ path: String, in sets: [DeliverySet]) -> DeliverySet.Folder? {
        let wanted = Self.path(URL(filePath: path, directoryHint: .isDirectory))
        return folders(of: sets).first { Self.path($0.url) == wanted }
    }

    /// The files of `set` still to write (`DeliveryPlan.Scope.pending`), none of them over an existing file.
    public static func deliveryTasks(for set: DeliverySet, existing: Set<String>) -> [DeliveryTask] {
        let tasks = DeliveryPlan.tasks(for: set, scope: .pending) { existing.contains($0.lowercased()) }
        var taken = existing.union(tasks.map { $0.fileName.lowercased() })
        return tasks.map { task in
            guard task.replacesExisting else { return task }
            var renamed = task
            renamed.fileName = OutputNamePattern.available(task.fileName) { taken.contains($0.lowercased()) }
            renamed.replacesExisting = false
            taken.insert(renamed.fileName.lowercased())
            return renamed
        }
    }

    /// Each video's take and sidecar names, as Export for Editing names them, none taken in the folder or by an
    /// earlier video of the same export.
    public static func editingNames(
        for items: [LibraryItemModel], preset: ExportPreset, existing: Set<String>
    ) -> [ExportNaming.Names] {
        var taken = existing
        return items.map { item in
            let names = ExportNaming.names(for: item.spec, presetName: item.presetName, preset: preset) {
                taken.contains($0.lowercased())
            }
            taken.insert(names.video.lowercased())
            taken.insert(names.sidecar.lowercased())
            return names
        }
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self
    }
}
