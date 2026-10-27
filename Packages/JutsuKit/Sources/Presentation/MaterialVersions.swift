import Foundation
import JutsuCore

/// A library item's earlier versions: the one its current version was made from, which Compare with Original puts
/// beside it, and the files Delete from Library trashes with the current one.
public enum MaterialVersions {
    /// The earlier version of the same item its current version names as its parent (an Enhance run on this Mac, an
    /// edit in another app), and its place among the versions, 0 for the first; `nil` for an item made in one go.
    public static func parent(of material: Material) -> (version: MaterialVersion, index: Int)? {
        guard
            let parent = material.current.inputs.first(where: {
                $0.role == .parent && $0.source.materialID == material.id && $0.source.versionID != material.current.id
            }),
            let index = material.versions.firstIndex(where: { $0.id == parent.source.versionID })
        else { return nil }
        return (material.versions[index], index)
    }

    /// The parent version (`parent(of:)`) with a file `exists` finds, which Compare with Original puts on the left.
    public static func original(of material: Material, exists: (URL) -> Bool) -> MaterialVersion? {
        guard let version = parent(of: material)?.version, let file = version.fileURL, exists(file) else { return nil }
        return version
    }

    /// The original's ID on a compare surface: its version's with every byte turned over, so it never equals the
    /// current one's, as a material's first version has the material's own ID, which the item has too.
    static func compareID(of version: MaterialVersion) -> UUID {
        var bytes = version.id.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            for index in raw.indices { raw[index] ^= 0xFF }
        }
        return UUID(uuid: bytes)
    }

    /// The original on the left and the current version on the right, each labelled so; `nil` without an original.
    public static func videoPair(
        _ material: Material, current item: LibraryItemModel, exists: (URL) -> Bool
    ) -> ComparePair? {
        guard let original = original(of: material, exists: exists), let file = original.fileURL else { return nil }
        let made = original.video ?? item.job
        // An ID of its own: the compare tells its two sides apart, and labels them, by item.
        var job = Job(
            id: compareID(of: original), spec: made.spec, providerKind: made.providerKind, owner: made.owner,
            cost: made.cost,
            createdAt: made.createdAt)
        job.state = .done
        job.outputFile = file
        job.outputMedia = original.video?.outputMedia
        return ComparePair(original: LibraryItemModel(job: job), edited: item)
    }

    /// The original image on the left and the current one on the right, captioned so.
    public static func imagePair(
        _ material: Material, current image: SavedImage, exists: (URL) -> Bool
    ) -> ImageComparePair? {
        guard let original = original(of: material, exists: exists), let file = original.fileURL else { return nil }
        return ImageComparePair(
            CompareImage(id: compareID(of: original), fileURL: file, prompt: ComparePair.originalLabel),
            CompareImage(id: image.id, fileURL: image.fileURL, prompt: ComparePair.editedLabel))
    }

    /// The files of the item's other versions that the app keeps (`owns`: in its output folders), once each: Delete
    /// from Library trashes them with the current file. A version that points at a file elsewhere stays untouched,
    /// and so does one a delivery set holds (`held`, version IDs): an exported set keeps its versions.
    public static func earlierFiles(of material: Material, held: Set<UUID>, owns: (URL) -> Bool) -> [URL] {
        let current = material.current.fileURL?.standardizedFileURL
        let kept = Set(material.versions.filter { held.contains($0.id) }.compactMap { $0.fileURL?.standardizedFileURL })
        var seen: Set<URL> = []
        return material.versions.compactMap { $0.fileURL?.standardizedFileURL }.filter {
            $0 != current && !kept.contains($0) && owns($0) && seen.insert($0).inserted
        }
    }

    /// The version IDs `sets` hold, which `earlierFiles` leaves alone.
    public static func held(by sets: [DeliverySet]) -> Set<UUID> {
        Set(sets.flatMap { $0.items.map(\.reference.versionID) })
    }
}
