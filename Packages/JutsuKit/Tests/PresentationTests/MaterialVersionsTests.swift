import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Compare with Original and the files Delete from Library takes along.
@Suite struct MaterialVersionsTests {
    let originalFile = URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/Videos/rooftop.mp4")
    let editedFile = URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/Videos/rooftop 4x.mp4")

    /// A video made once, then upscaled on this Mac into a second version linked to the first.
    private func upscaled() throws -> Material {
        var material = Material(kind: .video, version: MaterialVersion(fileURL: originalFile))
        let original = material.reference
        try material.addVersion(
            MaterialVersion(fileURL: editedFile, inputs: [MaterialInput(source: original, role: .parent)]))
        return material
    }

    @Test func theVersionAnItemWasMadeFromIsItsOriginal() throws {
        let material = try upscaled()
        let original = try #require(MaterialVersions.original(of: material, exists: { _ in true }))
        #expect(original.fileURL == originalFile)
        #expect(MaterialVersions.original(of: material, exists: { $0 != originalFile }) == nil)
        // Made in one go: nothing to compare with.
        let single = Material(kind: .video, version: MaterialVersion(fileURL: originalFile))
        #expect(MaterialVersions.original(of: single, exists: { _ in true }) == nil)
    }

    @Test func theVideoPairPutsTheOriginalLeftAndLabelsBothSides() throws {
        let material = try upscaled()
        var item = LibraryFixture.item()
        item.job.outputFile = editedFile

        let pair = try #require(MaterialVersions.videoPair(material, current: item, exists: { _ in true }))

        #expect(pair.left.outputFile == originalFile)
        #expect(pair.right.id == item.id)
        #expect(pair.tracks.map { $0.labels.first } == [ComparePair.originalLabel, ComparePair.editedLabel])
        #expect(Set(pair.tracks.map(\.id)).count == 2)
    }

    @Test func theImagePairCaptionsBothSides() throws {
        var material = Material(kind: .image, version: MaterialVersion(fileURL: URL(fileURLWithPath: "/o/a.png")))
        try material.addVersion(
            MaterialVersion(
                fileURL: URL(fileURLWithPath: "/o/a 4x.png"),
                inputs: [MaterialInput(source: material.reference, role: .parent)]))
        let image = try #require(MaterialLibrary.savedImage(material))

        let pair = try #require(MaterialVersions.imagePair(material, current: image, exists: { _ in true }))

        #expect(pair.left.fileURL.lastPathComponent == "a.png")
        #expect(pair.right.fileURL.lastPathComponent == "a 4x.png")
        #expect(pair.left.prompt == ComparePair.originalLabel)
    }

    @Test func onlyEarlierFilesTheAppKeepsAreTakenAlong() throws {
        var material = try upscaled()
        let outside = URL(fileURLWithPath: "/Volumes/Footage/edit.mov")
        try material.addVersion(MaterialVersion(fileURL: outside))
        try material.addVersion(MaterialVersion(fileURL: URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/x.mp4")))
        let owns = { (url: URL) in url.path.hasPrefix("/home/me/Movies/Jutsu Studio/") }

        let files = MaterialVersions.earlierFiles(of: material, held: [], owns: owns)

        #expect(files == [originalFile, editedFile])
        // A version a delivery set holds stays.
        let first = try #require(material.versions.first)
        #expect(MaterialVersions.earlierFiles(of: material, held: [first.id], owns: owns) == [editedFile])
    }

    @Test func anOriginalWithTheItemsOwnIDGetsAnotherOnTheCompare() throws {
        let version = MaterialVersion(fileURL: originalFile)
        #expect(MaterialVersions.compareID(of: version) != version.id)
        #expect(MaterialVersions.compareID(of: version) == MaterialVersions.compareID(of: version))
    }
}
