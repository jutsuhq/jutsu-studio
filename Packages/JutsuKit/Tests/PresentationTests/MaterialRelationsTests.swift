import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct MaterialRelationsTests {
    static let missing = URL(fileURLWithPath: "/tmp/missing.png")

    static func video(from inputs: [MaterialInput], minutesAgo: Double = 1, hidden: Bool = false) -> Material {
        var video = CatalogFixture.video(minutesAgo: minutesAgo)
        video.current.inputs = inputs
        video.isHidden = hidden
        return video
    }

    /// Every file exists except `missing`.
    static func relations(_ materials: [Material]) -> MaterialRelations {
        MaterialRelations(materials) { $0 != missing }
    }

    @Test func madeFromNamesTheExactVersionAndItsRole() throws {
        var image = CatalogFixture.image(prompt: "A knight at dawn")
        let first = image.reference
        try image.addVersion(MaterialVersion(fileURL: URL(fileURLWithPath: "/tmp/edit.png")))
        let reference = CatalogFixture.image(prompt: "Armor")
        let video = Self.video(from: [
            MaterialInput(source: first, role: .startFrame),
            MaterialInput(source: reference.reference, role: .reference, position: 1),
            MaterialInput(source: first, role: .sourceVideo),
        ])
        let links = Self.relations([image, reference, video]).madeFrom(video.reference)
        #expect(links.map(\.reference) == [first, reference.reference])
        #expect(links.map(\.role) == [.startFrame, .reference])
        #expect(links.map(\.roleTitle) == ["Start frame", "Reference 2"])
        // The version the job sent, not the edit made since.
        #expect(links[0].prompt == "A knight at dawn")
        #expect(links[0].previewURL == image.previousVersions[0].fileURL)
        #expect(links.allSatisfy { $0.availability == .listed })
    }

    @Test func aRemovedOrMissingSourceStaysMarkedUnavailable() {
        var removed = CatalogFixture.image()
        removed.current.fileURL = Self.missing
        removed.isHidden = true
        var picked = CatalogFixture.image()
        picked.isHidden = true
        let deleted = MaterialReference(materialID: UUID(), versionID: UUID())
        let video = Self.video(from: [
            MaterialInput(source: removed.reference, role: .startFrame),
            MaterialInput(source: picked.reference, role: .endFrame, position: 1),
            MaterialInput(source: deleted, role: .reference, position: 2),
        ])
        let links = Self.relations([removed, picked, video]).madeFrom(video.reference)
        #expect(links.map(\.availability) == [.unavailable, .notListed, .unavailable])
        #expect(links.map(\.availabilityNote) == ["Unavailable", "Not in the library", "Unavailable"])
        #expect(links[2].kind == .image)
        #expect(links[2].previewURL == nil)
    }

    @Test func usedInListsEveryVideoOfAnyVersionNewestFirst() throws {
        var image = CatalogFixture.image()
        let first = image.reference
        try image.addVersion(MaterialVersion(fileURL: URL(fileURLWithPath: "/tmp/edit.png")))
        let older = Self.video(from: [MaterialInput(source: first, role: .reference)], minutesAgo: 30)
        let newer = Self.video(from: [MaterialInput(source: image.reference, role: .endFrame)], minutesAgo: 2)
        var gone = Self.video(from: [MaterialInput(source: image.reference, role: .startFrame)], hidden: true)
        gone.current.fileURL = Self.missing
        let unrelated = Self.video(from: [])
        // An edit of the image is made from it too, but it isn't a video.
        var edit = CatalogFixture.image()
        edit.current.inputs = [MaterialInput(source: first, role: .parent)]
        let links = Self.relations([image, older, newer, gone, unrelated, edit]).usedIn(image.id)
        #expect(links.map(\.reference.materialID) == [gone.id, newer.id, older.id])
        #expect(links.map(\.role) == [.startFrame, .endFrame, .reference])
        #expect(links.map(\.kind) == [.video, .video, .video])
        #expect(links.map(\.availability) == [.unavailable, .listed, .listed])
    }
}
