import Foundation
import JutsuCore
import Testing

@testable import Presentation

@MainActor
private final class FakeTemplateRecords: TemplateRecords {
    var stored: [JobTemplate]
    var failsWrite = false

    init(_ stored: [JobTemplate] = []) { self.stored = stored }

    func names(excluding id: UUID?) -> [String] {
        stored.filter { $0.id != id }.map(\.name)
    }

    func add(_ template: JobTemplate) throws {
        if failsWrite { throw CocoaError(.fileWriteOutOfSpace) }
        stored.append(template)
    }

    func rename(_ id: UUID, to name: String) throws {
        if failsWrite { throw CocoaError(.fileWriteOutOfSpace) }
        if let index = stored.firstIndex(where: { $0.id == id }) { stored[index].name = name }
    }

    func delete(_ id: UUID) throws {
        if failsWrite { throw CocoaError(.fileWriteOutOfSpace) }
        stored.removeAll { $0.id == id }
    }
}

/// Copies into `/templates/<id>/`, keeping the file names; `unreadable` fails the copy.
private final class FakeTemplateImages: TemplateImages {
    var unreadable = false
    private(set) var folders: Set<UUID> = []

    func copy(_ references: [LocalImage], templateID: UUID) throws -> [URL] {
        if unreadable { throw CocoaError(.fileReadNoPermission) }
        folders.insert(templateID)
        return references.map {
            URL(fileURLWithPath: "/templates/\(templateID.uuidString)/\($0.fileURL.lastPathComponent)")
        }
    }

    func remove(templateID: UUID) {
        folders.remove(templateID)
    }
}

@MainActor
@Suite struct TemplateLibraryTests {
    static func draft(_ name: String) -> JobTemplate {
        JobTemplate(
            name: name, mode: .motionTransfer,
            references: [
                LocalImage(fileURL: URL(fileURLWithPath: "/home/me/a.png"), bookmark: Data([1])),
                LocalImage(fileURL: URL(fileURLWithPath: "/home/me/b.png"), prompt: "neon cat"),
            ],
            resolution: .p720)
    }

    @Test func aSavedTemplateGetsAFreeNameAndItsOwnCopies() throws {
        let records = FakeTemplateRecords([Self.draft("Dance")])
        let images = FakeTemplateImages()

        let saved = try TemplateLibrary(records: records, images: images).save(Self.draft("dance"))

        #expect(saved.name == "dance 2")
        #expect(saved.references.map(\.fileURL.path) == ["a.png", "b.png"].map { "/templates/\(saved.id)/\($0)" })
        #expect(saved.references.map(\.bookmark) == [nil, nil])
        #expect(saved.references.map(\.prompt) == [nil, "neon cat"])
        #expect(records.stored.last == saved)
    }

    @Test func anUnreadableImageSavesNothingAndSaysWhich() {
        let records = FakeTemplateRecords()
        let images = FakeTemplateImages()
        images.unreadable = true

        #expect(throws: TemplateSaveError.unreadableImage) {
            try TemplateLibrary(records: records, images: images).save(Self.draft("Dance"))
        }

        #expect(records.stored.isEmpty)
        let message = UserMessage.templateNotSaved(TemplateSaveError.unreadableImage)
        #expect(message.title == "Can't save the template")
        #expect(message.message == "A reference image can't be read. Add it again, then save the template.")
    }

    @Test func aFailedWriteRemovesTheCopiesAgain() {
        let records = FakeTemplateRecords()
        records.failsWrite = true
        let images = FakeTemplateImages()

        #expect(throws: CocoaError(.fileWriteOutOfSpace)) {
            try TemplateLibrary(records: records, images: images).save(Self.draft("Dance"))
        }

        #expect(images.folders.isEmpty)
        #expect(UserMessage.templateNotSaved(CocoaError(.fileWriteOutOfSpace)).title == "Can't save the template")
    }

    @Test func aRenameIgnoresTheTemplatesOwnName() throws {
        let dance = Self.draft("Dance")
        let records = FakeTemplateRecords([dance, Self.draft("Spin")])
        let library = TemplateLibrary(records: records, images: FakeTemplateImages())

        #expect(try library.rename(dance.id, to: "DANCE ") == "DANCE")
        #expect(try library.rename(dance.id, to: "spin") == "spin 2")
        #expect(records.stored.map(\.name) == ["spin 2", "Spin"])
    }

    @Test func imagesGoOnlyWithTheirTemplate() throws {
        let records = FakeTemplateRecords()
        let images = FakeTemplateImages()
        let library = TemplateLibrary(records: records, images: images)
        let saved = try library.save(Self.draft("Dance"))

        records.failsWrite = true
        #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try library.delete(saved.id) }
        #expect(images.folders == [saved.id])

        records.failsWrite = false
        try library.delete(saved.id)
        #expect(images.folders.isEmpty && records.stored.isEmpty)
    }
}
