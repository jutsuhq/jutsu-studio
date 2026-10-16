import Foundation
import JutsuCore

/// Recovery journal for paid images awaiting download; completed library entries live only in the catalog.
public actor PendingImageSaves {
    private let pendingURL: URL

    public init(folder: URL) { pendingURL = folder.appending(path: "pending-images.json") }

    /// The images still to save, oldest first. Ones that can't be read are left out.
    public func pending() throws -> [PendingImage] {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return [] }
        let data = try Data(contentsOf: pendingURL)
        return try Self.decoder.decode([PendingImage].self, from: data)
    }

    public func addPending(_ new: [PendingImage]) throws {
        let current = try pending()
        try writePending(current + new.filter { image in !current.contains { $0.id == image.id } })
    }

    public func removePending(_ ids: Set<UUID>) throws {
        let current = try pending()
        guard current.contains(where: { ids.contains($0.id) }) else { return }
        try writePending(current.filter { !ids.contains($0.id) })
    }

    private func writePending(_ images: [PendingImage]) throws {
        try FileManager.default.createDirectory(
            at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(images).write(to: pendingURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
