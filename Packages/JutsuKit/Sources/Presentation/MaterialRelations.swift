import Foundation
import JutsuCore

/// One end of a "made from" relation as the Library shows it: the exact catalog version, the part the image played,
/// and whether it can still be opened. A source that was removed or whose file is gone stays, marked unavailable.
public struct MaterialLink: Sendable, Hashable, Identifiable {
    public enum Availability: Sendable, Hashable {
        /// The Library lists it: a file on this Mac, or an account result.
        case listed
        /// The file is here, but the Library doesn't list it: picked in Finder or pasted rather than made in the app.
        case notListed
        /// Removed from the library or deleted, its file gone or on a drive that isn't connected.
        case unavailable
    }

    public var reference: MaterialReference
    public var kind: Material.Kind
    /// The part the image played in the video.
    public var role: MaterialInput.Role
    /// 0-based among the job's images.
    public var position: Int
    /// The file on this Mac, else where the account keeps it; `nil` when neither is known.
    public var previewURL: URL?
    public var prompt: String
    public var createdAt: Date?
    public var availability: Availability

    public var id: String { "\(reference.materialID)/\(reference.versionID)/\(role.rawValue)/\(position)" }

    /// "Start frame", "End frame", "Reference 2".
    public var roleTitle: String {
        switch role {
        case .startFrame: FrameSlot.start.title
        case .endFrame: FrameSlot.end.title
        case .reference: String(localized: "Reference \(position + 1)", bundle: .module)
        case .sourceVideo: String(localized: "Source video", bundle: .module)
        case .parent: String(localized: "Edited from", bundle: .module)
        }
    }

    /// Shown under an unavailable or unlisted source.
    public var availabilityNote: String? {
        switch availability {
        case .listed: nil
        case .notListed: String(localized: "Not in the library", bundle: .module)
        case .unavailable: String(localized: "Unavailable", bundle: .module)
        }
    }
}

/// The images a video was made from and the videos made from an image, read from one snapshot of the catalog. The
/// lookups scan it, so they are for one details view, never per grid card.
public struct MaterialRelations: Sendable {
    /// The roles an image plays in a video (`ImageRole`).
    static let imageRoles: Set<MaterialInput.Role> = [.startFrame, .endFrame, .reference]

    private let materials: [Material]
    private let byID: [UUID: Material]
    private let fileExists: @Sendable (URL) -> Bool

    public init(
        _ materials: [Material],
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.materials = materials
        byID = Dictionary(materials.map { ($0.id, $0) }) { first, _ in first }
        self.fileExists = fileExists
    }

    /// The version `reference` names; `nil` when the material or that version is gone.
    public func version(_ reference: MaterialReference) -> MaterialVersion? {
        byID[reference.materialID]?.versions.first { $0.id == reference.versionID }
    }

    /// The images the version was made from, in the order its job sent them: the frames, then the references.
    public func madeFrom(_ reference: MaterialReference) -> [MaterialLink] {
        (version(reference)?.inputs ?? []).filter { Self.imageRoles.contains($0.role) }.map {
            link(to: $0.source, role: $0.role, position: $0.position, kind: .image)
        }
    }

    /// The videos made from any version of the material, newest first, each with the part the image played.
    public func usedIn(_ materialID: UUID) -> [MaterialLink] {
        materials.filter { $0.kind == .video }.flatMap { video in
            video.versions.flatMap { version in
                version.inputs.filter { $0.source.materialID == materialID && Self.imageRoles.contains($0.role) }.map {
                    link(
                        to: MaterialReference(materialID: video.id, versionID: version.id), role: $0.role,
                        position: $0.position, kind: .video)
                }
            }
        }
        .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    /// The version as a link, for a details view of it; `kind` stands in while its material is gone.
    public func link(
        to reference: MaterialReference, role: MaterialInput.Role = .reference, position: Int = 0,
        kind: Material.Kind = .image
    ) -> MaterialLink {
        let material = byID[reference.materialID]
        let version = version(reference)
        return MaterialLink(
            reference: reference, kind: material?.kind ?? kind, role: role, position: position,
            previewURL: version.flatMap { $0.fileURL ?? $0.remoteURL }, prompt: version?.generation?.prompt ?? "",
            createdAt: version?.createdAt, availability: availability(of: material, version: version))
    }

    private func availability(of material: Material?, version: MaterialVersion?) -> MaterialLink.Availability {
        guard let material, let version else { return .unavailable }
        if let file = version.fileURL {
            guard fileExists(file) else { return .unavailable }
            return material.isHidden ? .notListed : .listed
        }
        // Kept by the account: a result the Library lists from it, or media a job sent by its link.
        guard version.remoteURL != nil else { return .unavailable }
        return material.isHidden ? .notListed : .listed
    }
}
