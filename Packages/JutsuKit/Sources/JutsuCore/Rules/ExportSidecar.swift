import Foundation

/// The JSON written next to an editing export: what the take was made from, for the edit bay and for
/// support requests. File names only, never paths or bookmarks; no credentials or provider URLs.
public struct ExportSidecar: Codable, Sendable, Hashable {
    public struct Source: Codable, Sendable, Hashable {
        public var fileName: String
        /// Seconds from the start of the source file.
        public var rangeStart: TimeInterval
        public var rangeEnd: TimeInterval
    }

    public struct Style: Codable, Sendable, Hashable {
        public var id: UUID
        /// `nil` when the catalog didn't know the preset.
        public var name: String?
    }

    public struct Price: Codable, Sendable, Hashable {
        /// Decimal string, so it reads back exactly.
        public var amount: String
        /// `usd` or `credits`.
        public var unit: String
        public var isEstimate: Bool
    }

    public var app: String
    public var exportPreset: ExportPreset
    public var exportedAt: Date
    public var jobID: UUID
    public var mode: Mode
    /// `nil` for a clip made without a source video.
    public var source: Source?
    /// Reference image file names, in the order they were sent.
    public var references: [String]
    public var style: Style?
    public var prompt: String
    public var resolution: Resolution
    public var isDraft: Bool
    public var audio: AudioOption
    public var requestID: String?
    public var cost: Price
    public var createdAt: Date
    public var finishedAt: Date?

    public init(job: Job, presetName: String?, exportPreset: ExportPreset, exportedAt: Date) {
        let spec = job.spec
        app = "Jutsu Studio"
        self.exportPreset = exportPreset
        self.exportedAt = exportedAt
        jobID = job.id
        mode = spec.mode
        source = spec.source.map {
            Source(
                fileName: $0.fileURL.lastPathComponent, rangeStart: $0.range.lowerBound, rangeEnd: $0.range.upperBound)
        }
        references = spec.references.map(\.fileURL.lastPathComponent)
        style = spec.presetID.map { Style(id: $0, name: presetName) }
        prompt = spec.prompt
        resolution = spec.resolution
        isDraft = spec.isDraft
        audio = spec.audio
        requestID = job.remote?.requestID
        let price = job.price
        cost = Price(amount: price.amount.description, unit: price.unit.rawValue, isEstimate: price.isEstimate)
        createdAt = job.createdAt
        finishedAt = job.finishedAt
    }

    /// Pretty-printed with sorted keys and ISO 8601 dates.
    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ExportSidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportSidecar.self, from: data)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension ExportSidecar {
    /// One file of a delivery manifest.
    public struct DeliveryFile: Codable, Sendable, Hashable {
        /// `nil` when nothing was written.
        public var fileName: String?
        public var materialID: UUID
        public var versionID: UUID
        public var item: String
        public var output: String
        public var status: DeliveryResult.Status
        public var message: String?
    }

    /// The JSON written next to a delivery set's files: which exact catalog version each file is, in which output,
    /// and what failed or was skipped. Names and IDs only, never paths or bookmarks.
    public struct Delivery: Codable, Sendable, Hashable {
        public var app: String
        public var setID: UUID
        public var name: String
        public var exportedAt: Date
        public var note: String
        public var reviewLink: String
        public var files: [DeliveryFile]

        /// Every result the set has, in item and output order.
        public init(set: DeliverySet, exportedAt: Date) {
            app = "Jutsu Studio"
            setID = set.id
            name = set.name
            self.exportedAt = exportedAt
            note = set.note
            reviewLink = set.reviewLink
            let labels = ExportNaming.outputLabels(set.outputs)
            files = set.items.flatMap { item in
                set.outputs.compactMap { output -> DeliveryFile? in
                    guard let result = set.result(for: item, output: output) else { return nil }
                    return DeliveryFile(
                        fileName: result.fileName, materialID: item.reference.materialID,
                        versionID: item.reference.versionID, item: item.name,
                        output: labels[output.id] ?? output.summary, status: result.status, message: result.message)
                }
            }
        }

        /// Pretty-printed with sorted keys and ISO 8601 dates, like the editing sidecar.
        public func encoded() throws -> Data {
            try ExportSidecar.encoder.encode(self)
        }
    }
}
