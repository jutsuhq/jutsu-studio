import Foundation
import JutsuCore

/// `library_get`: one Library result in full, read from the catalog as the Library's details show it: the whole
/// prompt, the files that went in, in the order its job sent them (`MaterialRelations` for the Library items they
/// are), and the settings it was made with. Rejected results too; read-only.
public struct AgentLibraryDetail: Sendable, Hashable {
    public enum InputRole: Sendable, Hashable {
        case source, startFrame, endFrame, reference
        /// The result an Enhance operation, a final or an edit was made from.
        case editedFrom
    }

    public struct Input: Sendable, Hashable {
        public var role: InputRole
        /// 1-based among the job's images; `nil` for the source and `editedFrom`.
        public var position: Int?
        /// The file on this Mac, when it is one.
        public var file: URL?
        /// The Library item it is, when the Library lists it.
        public var item: UUID?
        public var isOnHiggsfield: Bool
        /// The source's range, in seconds from the start of its file.
        public var range: ClosedRange<TimeInterval>?
    }

    public struct Settings: Sendable, Hashable {
        public var resolution: String?
        // swiftlint:disable:next discouraged_optional_boolean
        public var isDraft: Bool?
        /// The agents' name of the audio option.
        public var audio: String?
        public var style: UUID?
        public var length: TimeInterval?
        public var aspectRatio: String?
        // swiftlint:disable:next discouraged_optional_boolean
        public var paidWithUnlimited: Bool?
        /// The agents' name of the Enhance operation.
        public var operation: String?
        /// Images the request made.
        public var count: Int?
    }

    /// As `library_search` lists it, with the whole prompt.
    public var hit: AgentLibraryHit
    public var inputs: [Input]
    public var settings: Settings

    /// The details of `ids`, in the order asked, and the IDs that aren't results with a file on this Mac.
    public static func of(_ ids: [UUID], in materials: [Material]) -> (details: [AgentLibraryDetail], missing: [UUID]) {
        let index = LibraryCatalogIndex(materials)
        let byID = Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = Dictionary(
            materials.compactMap(MaterialLibrary.row).filter(\.isLocal).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let relations = MaterialRelations(materials)
        var details: [AgentLibraryDetail] = []
        var missing: [UUID] = []
        for id in ids {
            guard let row = rows[id], let material = byID[id],
                let hit = AgentLibrarySearch.hit(row, material: material, index: index, promptLength: nil)
            else {
                missing.append(id)
                continue
            }
            let listed = { (id: UUID?) in id.flatMap { byID[$0] }.flatMap { $0.isHidden ? nil : $0.id } }
            switch row {
            case .video(let item):
                details.append(
                    AgentLibraryDetail(
                        hit: hit, inputs: inputs(of: item, version: material.current, listed: listed),
                        settings: settings(of: item.job)))
            case .localImage:
                details.append(
                    AgentLibraryDetail(
                        hit: hit, inputs: imageInputs(of: material.current, relations: relations, listed: listed),
                        settings: imageSettings(of: material.current)))
            case .remoteImage:
                missing.append(id)
            }
        }
        return (details, missing)
    }

    /// The source, or the result an operation worked on, then the images in the job's order.
    private static func inputs(
        of item: LibraryItemModel, version: MaterialVersion, listed: (UUID?) -> UUID?
    ) -> [Input] {
        let spec = item.spec
        let uploaded = item.job.inputs ?? spec.remoteInputs
        let relation = { (roles: Set<MaterialInput.Role>, position: Int?) in
            version.inputs.first { roles.contains($0.role) && (position == nil || $0.position == position) }?
                .source.materialID
        }
        var inputs: [Input] = []
        if let source = spec.source {
            let isOperation = spec.operation != nil
            let made = isOperation ? relation([.parent], nil) ?? item.job.parentID : relation([.sourceVideo], nil)
            inputs.append(
                Input(
                    role: isOperation ? .editedFrom : .source, position: nil, file: local(source.fileURL),
                    item: listed(made),
                    isOnHiggsfield: uploaded?.video != nil || spec.operation?.sourceJobID != nil,
                    range: isOperation ? nil : source.range))
        }
        if spec.operation == nil, let parent = listed(relation([.parent], nil) ?? item.job.parentID) {
            inputs.append(Input(role: .editedFrom, item: parent, isOnHiggsfield: false))
        }
        for (offset, reference) in spec.references.enumerated() {
            let role: InputRole =
                switch (spec.referencesAreFrames, offset) {
                case (true, 0): .startFrame
                case (true, _): .endFrame
                default: .reference
                }
            inputs.append(
                Input(
                    role: role, position: offset + 1, file: local(reference.fileURL),
                    item: listed(relation(MaterialRelations.imageRoles, offset)),
                    isOnHiggsfield: (uploaded?.images.count ?? 0) > offset || reference.serverMedia != nil
                        || !reference.fileURL.isFileURL))
        }
        return inputs
    }

    /// An image's inputs, the images it edited, in the order they were sent.
    private static func imageInputs(
        of version: MaterialVersion, relations: MaterialRelations, listed: (UUID?) -> UUID?
    ) -> [Input] {
        version.inputs.filter { $0.role == .reference }.sorted { $0.position < $1.position }.map { input in
            let source = relations.version(input.source)
            return Input(
                role: .reference, position: input.position + 1, file: source?.fileURL.flatMap(local),
                item: listed(input.source.materialID), isOnHiggsfield: source?.remoteURL != nil)
        }
    }

    private static func settings(of job: Job) -> Settings {
        let spec = job.spec
        return Settings(
            resolution: spec.operation == nil ? spec.resolution.rawValue : nil,
            isDraft: spec.operation == nil ? spec.isDraft : nil,
            audio: spec.operation == nil ? AgentVideoOrder.audioOptions.first { $0.value == spec.audio }?.key : nil,
            style: spec.presetID, length: spec.length, aspectRatio: spec.aspectRatio?.rawValue,
            paidWithUnlimited: job.remote?.paidWithUnlimited ?? spec.usesUnlimited,
            operation: spec.operation.map { name(of: $0.action.kind) }, count: nil)
    }

    /// What the request said, when the catalog kept it.
    private static func imageSettings(of version: MaterialVersion) -> Settings {
        let request = version.generation?.parameters.flatMap { try? JSONDecoder().decode(ImageRequest.self, from: $0) }
        return Settings(aspectRatio: request?.aspectRatio ?? version.aspectRatio, count: request?.count)
    }

    /// The agents' name of an Enhance operation, as `enhance` takes it.
    static func name(of kind: PostAction.Kind) -> String {
        switch kind {
        case .upscale: "upscale"
        case .reframe: "reframe"
        case .removeBackground: "remove_background"
        case .dub: "dub"
        case .changeVoice: "change_voice"
        }
    }

    private static func local(_ url: URL) -> URL? { url.isFileURL ? url : nil }
}
