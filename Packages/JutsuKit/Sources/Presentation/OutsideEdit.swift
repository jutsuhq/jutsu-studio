import Foundation
import JutsuCore

/// The round trip through another app: "Edit in…" opens a working copy of an exact version, never the original, and
/// the edited file comes back (dropped on its card or picked with Import as New Version) as a copy in the output
/// folder that becomes the material's new version, linked to the version it was made from.
///
/// A working copy sits in `<root>/<materialID>_<versionID>_<n>/`, so a file saved there, in place or under another
/// name, still says which version it was made from after a relaunch.
public enum OutsideEdit {
    /// Copies `file`, the file of `version`, into a folder of its own under `root`; `file` is only read.
    public static func workingCopy(of file: URL, version: MaterialReference, in root: URL) throws -> URL {
        let folder = root.appending(
            path: "\(version.materialID.uuidString)_\(version.versionID.uuidString)_\(UUID().uuidString.prefix(8))",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: file.lastPathComponent, directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// The version a working copy under `root` was made from; `nil` for any other file.
    public static func source(of file: URL, in root: URL) -> MaterialReference? {
        let folder = file.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
            return nil
        }
        let parts = folder.lastPathComponent.split(separator: "_")
        guard parts.count == 3, let material = UUID(uuidString: String(parts[0])),
            let version = UUID(uuidString: String(parts[1]))
        else { return nil }
        return MaterialReference(materialID: material, versionID: version)
    }

    /// The version an edit of `material` brought back as `file` is linked to: the one its working copy was made from
    /// when it is a version of this material, else the current one.
    public static func parent(of file: URL, for material: Material, root: URL) -> MaterialReference {
        guard let source = source(of: file, in: root), source.materialID == material.id,
            material.versions.contains(where: { $0.id == source.versionID })
        else { return material.reference }
        return source
    }

    /// Copies the edited `file` into `folder` as "<name> edited.<ext>" (" 2", " 3"… when taken). The edited file
    /// and every other file in `folder` are left as they are.
    public static func copyBack(_ file: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = file.deletingPathExtension().lastPathComponent
        let name = file.pathExtension.isEmpty ? "\(stem) edited" : "\(stem) edited.\(file.pathExtension)"
        let copy = folder.appending(path: name, directoryHint: .notDirectory).unusedFileURL()
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// Whether `file` is one of the material's own version files: a card dragged onto itself is not an edit.
    public static func isOwnFile(_ file: URL, of material: Material) -> Bool {
        let path = file.standardizedFileURL.path
        return material.versions.contains { $0.fileURL?.standardizedFileURL.path == path }
    }
}
