import Foundation

public struct MaterialReference: Codable, Sendable, Hashable {
    public var materialID: UUID
    public var versionID: UUID

    public init(materialID: UUID, versionID: UUID) {
        self.materialID = materialID
        self.versionID = versionID
    }
}

public struct MaterialInput: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        case sourceVideo, startFrame, endFrame, reference, parent
    }

    public var source: MaterialReference
    public var role: Role
    public var position: Int

    public init(source: MaterialReference, role: Role, position: Int = 0) {
        self.source = source
        self.role = role
        self.position = position
    }
}

/// Identity belongs to a provider connection, not to an expiring download URL.
public struct MaterialRemote: Codable, Sendable, Hashable {
    public var provider: ProviderKind
    public var owner: String?
    public var id: String
    public var output: Int

    public init(provider: ProviderKind, owner: String?, id: String, output: Int = 0) {
        self.provider = provider
        self.owner = owner
        self.id = id
        self.output = output
    }

    public var key: String {
        // Encoding components avoids collisions between IDs containing separators.
        let parts = [provider.rawValue, owner, id, String(output)]
        return parts.map { $0.map { "\($0.utf8.count):\($0)" } ?? "-" }.joined(separator: "|")
    }
}

public struct MaterialGeneration: Codable, Sendable, Hashable {
    public var prompt: String
    public var model: String
    /// The exact known request, encoded as JSON. Absent for imported files and unknown provider parameters.
    public var parameters: Data?
    /// An agent's name for the images, shown instead of the prompt (`JobSpec.title(from:)`); `nil` otherwise, and in
    /// materials saved before it existed.
    public var title: String?

    public init(prompt: String, model: String, parameters: Data? = nil, title: String? = nil) {
        self.prompt = prompt
        self.model = model
        self.parameters = parameters
        self.title = title
    }
}

/// Whether a version made the cut. Separate from the star and from any client status: rejecting hides a version
/// from the Library, it never deletes anything.
public enum Culling: String, Codable, Sendable, CaseIterable {
    case unreviewed, kept, rejected
}

public struct MaterialVersion: Codable, Sendable, Hashable, Identifiable {
    public enum Availability: Sendable, Equatable { case available, unavailable, remote }

    public var id: UUID
    public var createdAt: Date
    public var fileURL: URL?
    public var remoteURL: URL?
    public var bookmark: Data?
    public var generation: MaterialGeneration?
    public var inputs: [MaterialInput]
    public var aspectRatio: String?
    public var pixelSize: PixelSize?
    /// Execution details used by the existing video actions. Library identity and stars belong to Material.
    public var video: Job?
    /// Each version is culled on its own: a new edit starts unreviewed.
    public var culling: Culling = .unreviewed

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), fileURL: URL? = nil, remoteURL: URL? = nil,
        bookmark: Data? = nil, generation: MaterialGeneration? = nil, inputs: [MaterialInput] = [],
        aspectRatio: String? = nil, pixelSize: PixelSize? = nil, video: Job? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.fileURL = fileURL
        self.remoteURL = remoteURL
        self.bookmark = bookmark
        self.generation = generation
        self.inputs = inputs
        self.aspectRatio = aspectRatio
        self.pixelSize = pixelSize
        self.video = video
    }

    public var availability: Availability {
        guard let fileURL else { return .remote }
        return FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) ? .available : .unavailable
    }
}

/// A catalog entry. Alternate generations are separate materials with a shared variantGroupID.
public struct Material: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case video, image }
    public enum Origin: String, Codable, Sendable { case local, higgsfield }

    public var id: UUID
    public var kind: Kind
    public var origin: Origin
    public var remote: MaterialRemote?
    public var createdAt: Date
    public var isStarred: Bool
    public var isHidden = false
    public var variantGroupID: UUID?
    /// The variant chosen as the face of its group's card. At most one per group; with none, the grid picks.
    public var isVariantPrimary = false
    public var current: MaterialVersion
    public private(set) var previousVersions: [MaterialVersion] = []

    public init(
        id: UUID = UUID(), kind: Kind, origin: Origin = .local, remote: MaterialRemote? = nil,
        createdAt: Date = Date(), isStarred: Bool = false, variantGroupID: UUID? = nil,
        version: MaterialVersion
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.remote = remote
        self.createdAt = createdAt
        self.isStarred = isStarred
        self.variantGroupID = variantGroupID
        current = version
    }

    public var reference: MaterialReference { MaterialReference(materialID: id, versionID: current.id) }
    public var versions: [MaterialVersion] { previousVersions + [current] }

    public mutating func addVersion(_ version: MaterialVersion) throws {
        guard !versions.contains(where: { $0.id == version.id }) else { throw MaterialError.duplicateVersion }
        previousVersions.append(current)
        current = version
    }

    /// Library removal. An account result goes back to being listed from the account; a local one stops being
    /// listed but keeps its identity as a source of other versions.
    public mutating func removeFromLibrary() {
        guard remote != nil, current.remoteURL != nil else {
            isHidden = true
            return
        }
        current.fileURL = nil
        current.bookmark = nil
        current.video?.outputFile = nil
    }

    public mutating func updateVersion(_ version: MaterialVersion) throws {
        if version.id == current.id {
            current = version
        } else if let index = previousVersions.firstIndex(where: { $0.id == version.id }) {
            previousVersions[index] = version
        } else {
            throw MaterialError.missingMaterial
        }
    }
}

public enum MaterialError: Error { case duplicateVersion, invalidRecord, missingMaterial }
