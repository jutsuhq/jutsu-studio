import Foundation
import JutsuCore
import Persistence
import Testing

@Suite struct PendingImageSavesTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "PendingImageSaves-\(UUID())")
    @Test func pendingImagesAreKeptUntilRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = PendingImageSaves(folder: folder)
        func pending(_ name: String) -> PendingImage {
            PendingImage(
                id: UUID(), remoteURL: URL(string: "https://cdn.example.com/\(name).png")!, prompt: name,
                model: "Soul", aspectRatio: nil, createdAt: Date(timeIntervalSince1970: 0))
        }
        let first = pending("first")
        let second = pending("second")
        try await index.addPending([first, second])
        try await index.addPending([first])
        #expect(try await index.pending() == [first, second])

        try await index.removePending([first.id])
        #expect(try await PendingImageSaves(folder: folder).pending() == [second])
    }
}
