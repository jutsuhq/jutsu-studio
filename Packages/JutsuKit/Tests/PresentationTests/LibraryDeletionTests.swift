import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// Files are "there" unless listed as missing; moving one listed as stuck fails.
private final class FakeTrash: LibraryTrash {
    var missing: Set<URL> = []
    var stuck: Set<URL> = []
    private(set) var trashed: [URL] = []

    func fileExists(at url: URL) -> Bool { !missing.contains(url) }

    func moveToTrash(_ url: URL) throws {
        if stuck.contains(url) { throw CocoaError(.fileWriteNoPermission) }
        trashed.append(url)
    }
}

@MainActor
private final class FakeRecords: LibraryRecords {
    var failsSave = false
    private(set) var deleted: [UUID] = []
    private(set) var saves = 0

    func delete(_ id: UUID) { deleted.append(id) }

    func save() throws {
        saves += 1
        if failsSave { throw CocoaError(.fileWriteOutOfSpace) }
    }
}

@MainActor
@Suite struct LibraryDeletionTests {
    static func item(_ name: String?) -> LibraryItemModel {
        var item = LibraryFixture.item()
        item.job.outputFile = name.map { URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/\($0).mp4") }
        return item
    }

    @Test func everythingDeletedSaysNothing() {
        let items = [Self.item("a"), Self.item(nil)]
        let trash = FakeTrash()
        let records = FakeRecords()

        let message = LibraryDeletion.delete(items, trash: trash, records: records)

        #expect(message == nil)
        #expect(trash.trashed == [items[0].outputFile])
        #expect(records.deleted == items.map(\.id) && records.saves == 1)
    }

    @Test func aFileThatCantBeTrashedKeepsItsRecordAndIsReported() throws {
        let items = [Self.item("kept"), Self.item("gone"), Self.item("missing")]
        let trash = FakeTrash()
        trash.stuck = [try #require(items[0].outputFile)]
        trash.missing = [try #require(items[2].outputFile)]
        let records = FakeRecords()

        let message = try #require(LibraryDeletion.delete(items, trash: trash, records: records))

        #expect(records.deleted == [items[1].id, items[2].id])
        #expect(trash.trashed == [items[1].outputFile])
        #expect(message.title == "Can't move the file to the Trash")
        #expect(message.message == CocoaError(.fileWriteNoPermission).localizedDescription)
    }

    @Test func severalFilesLeftAreCounted() throws {
        let items = [Self.item("a"), Self.item("b"), Self.item("c")]
        let trash = FakeTrash()
        trash.stuck = Set(items.prefix(2).compactMap(\.outputFile))
        let records = FakeRecords()

        let message = try #require(LibraryDeletion.delete(items, trash: trash, records: records))

        #expect(records.deleted == [items[2].id])
        #expect(message.title == "Can't move 2 files to the Trash")
        #expect(message.message.hasPrefix("They stay in the Library. "))
    }

    @Test func earlierVersionsGoToTheTrashWithTheCurrentFile() throws {
        let items = [Self.item("upscaled"), Self.item("other")]
        let earlier = URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/original.mp4")
        let trash = FakeTrash()
        let records = FakeRecords()

        let message = LibraryDeletion.delete(
            items, trash: trash, records: records, earlierFiles: { $0 == items[0].id ? [earlier] : [] })

        #expect(message == nil)
        #expect(trash.trashed == [earlier, items[0].outputFile, items[1].outputFile])
        #expect(records.deleted == items.map(\.id))
    }

    @Test func anEarlierVersionThatCantBeTrashedKeepsTheItem() throws {
        let item = Self.item("upscaled")
        let earlier = URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/original.mp4")
        let trash = FakeTrash()
        trash.stuck = [earlier]
        let records = FakeRecords()

        _ = try #require(
            LibraryDeletion.delete([item], trash: trash, records: records, earlierFiles: { _ in [earlier] }))

        #expect(trash.trashed.isEmpty)
        #expect(records.deleted.isEmpty)
    }

    @Test func aRunOnTheItemStopsBeforeItsFilesGo() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "LibraryDeletion-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "LibraryDeletionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let engine = FakeOnDeviceEngine()
        var registered = 0
        let runs = OnDeviceRuns(engine: engine, consent: OnDeviceModelConsent(defaults: defaults)) { _, _, _ in
            registered += 1
        }
        let item = Self.item("rooftop")
        let videos = folder.appending(path: "Videos")
        runs.start(
            OnDeviceRuns.Request(
                source: MaterialReference(materialID: item.id, versionID: item.id),
                file: folder.appending(path: "a.mp4"),
                action: .smoothMotion(.fps60), destination: videos, scratch: videos))
        await eventually { engine.isRunning }
        let trash = FakeTrash()
        let records = FakeRecords()

        let message = await LibraryDeletion.delete([item], stopping: runs, trash: trash, records: records)

        #expect(message == nil && records.deleted == [item.id])
        #expect(runs.runs.isEmpty && !engine.isRunning && registered == 0)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: videos.path)) ?? []).isEmpty)
    }

    @Test func aFailedSaveIsReportedBeforeAnyTrashFailure() throws {
        let items = [Self.item("a"), Self.item("b")]
        let trash = FakeTrash()
        trash.stuck = [try #require(items[0].outputFile)]
        let records = FakeRecords()
        records.failsSave = true

        let message = try #require(LibraryDeletion.delete(items, trash: trash, records: records))

        #expect(message.title == "Can't remove the result from the Library")
        #expect(message.message == CocoaError(.fileWriteOutOfSpace).localizedDescription)
    }
}
