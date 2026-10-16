import Foundation
import JutsuCore
import Testing

@testable import Presentation

@MainActor
@Suite struct DeliveryRunTests {
    private struct Broken: Error, LocalizedError {
        var errorDescription: String? { "disk full" }
    }

    private static let outputs = [
        DeliveryOutput(name: "web", preset: .image(ImageExportPreset(format: .jpeg))),
        DeliveryOutput(name: "print", preset: .image(ImageExportPreset(format: .png))),
    ]

    private func set(images count: Int) -> DeliverySet {
        let materials = (1...count).map {
            Material(kind: .image, version: MaterialVersion(fileURL: URL(filePath: "/library/img\($0).png")))
        }
        return DeliverySet(name: "Set", items: DeliverySet.items(from: materials), outputs: Self.outputs)
    }

    @Test func aFailureIsNotedAndTheRunGoesOn() async {
        var delivery = set(images: 3)
        let tasks = DeliveryPlan.tasks(for: delivery, scope: .all) { _ in false }
        let failing = tasks[2].id
        let missing = tasks[5].id
        var states: [String: DeliveryRun.State] = [:]

        let results = await DeliveryRun.run(tasks) { task in
            if task.id == failing { throw Broken() }
            if task.id == missing { throw DeliverySetError.sourceUnavailable }
        } report: {
            states[$0] = $1
        }
        delivery.record(results, in: .init(url: URL(filePath: "/out")), at: Date())

        #expect(results.count == 6)
        #expect(states[failing] == .failed("disk full"))
        #expect(states[missing] == .skipped(DeliveryContent.unavailableMessage))
        #expect(states.values.filter { $0 == DeliveryRun.State.done }.count == 4)
        let counts = DeliveryCounts(delivery)
        #expect(counts.done == 4 && counts.failed == 1 && counts.skipped == 1)
        #expect(delivery.isFrozen)
    }

    @Test func retryWritesOnlyTheFailedFiles() async {
        var delivery = set(images: 4)
        let tasks = DeliveryPlan.tasks(for: delivery, scope: .all) { _ in false }
        let failing: Set<String> = [tasks[1].id, tasks[6].id]
        let first = await DeliveryRun.run(tasks) { task in
            if failing.contains(task.id) { throw Broken() }
        }
        delivery.record(first, in: .init(url: URL(filePath: "/out")), at: Date())

        // The folder holds what the first run wrote.
        let existing = Set(first.compactMap(\.fileName).map { $0.lowercased() })
        var written: [String] = []
        let retry = DeliveryPlan.tasks(for: delivery, scope: .failed) { existing.contains($0.lowercased()) }
        let second = await DeliveryRun.run(retry) { written.append($0.id) }
        delivery.record(second, in: .init(url: URL(filePath: "/out")), at: Date())

        #expect(Set(written) == failing)
        #expect(retry.map(\.fileName) == [tasks[1].fileName, tasks[6].fileName])
        #expect(DeliveryCounts(delivery).failed == 0)
        #expect(DeliveryCounts(delivery).done == 8)
        #expect(DeliveryPlan.tasks(for: delivery, scope: .failed) { _ in false }.isEmpty)
    }

    @Test func aCanceledRunNotesOnlyWhatFinished() async {
        let tasks = DeliveryPlan.tasks(for: set(images: 3), scope: .all) { _ in false }
        let stopAt = tasks[2].id

        let results = await DeliveryRun.run(tasks) { task in
            if task.id == stopAt { throw CancellationError() }
        }

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.status == .done })
    }

    @Test func theStatusSaysWhenAndWhere() {
        var delivery = set(images: 1)
        #expect(DeliveryContent.status(of: delivery) == "Not exported")
        #expect(DeliveryContent.summary(DeliveryCounts(delivery)) == nil)

        let tasks = DeliveryPlan.tasks(for: delivery, scope: .all) { _ in false }
        delivery.record(
            [tasks[0].result(.done), tasks[1].result(.failed, message: "x")], in: .init(url: URL(filePath: "/Client")),
            at: Date())

        #expect(DeliveryContent.status(of: delivery).hasSuffix("to Client"))
        #expect(DeliveryContent.summary(DeliveryCounts(delivery)) == "1 done · 1 failed")
    }
}

@Suite struct OutsideEditTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "OutsideEdit-\(UUID())")

    @Test func aWorkingCopySaysWhichVersionItCameFromAndLeavesTheOriginal() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appending(path: "Images")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let original = library.appending(path: "hero.png")
        try Data("original".utf8).write(to: original)
        var material = Material(kind: .image, version: MaterialVersion(fileURL: original))
        let source = material.reference
        let root = folder.appending(path: "Edit In")

        let copy = try OutsideEdit.workingCopy(of: original, version: source, in: root)
        try Data("edited".utf8).write(to: copy)
        let savedAs = copy.deletingLastPathComponent().appending(path: "hero final.tif")
        try Data("edited".utf8).write(to: savedAs)
        try material.addVersion(MaterialVersion(fileURL: library.appending(path: "other.png")))

        #expect(copy.lastPathComponent == "hero.png")
        #expect(OutsideEdit.source(of: copy, in: root) == source)
        #expect(OutsideEdit.parent(of: savedAs, for: material, root: root) == source)
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test func aFileFromElsewhereIsAnEditOfTheCurrentVersion() throws {
        let material = Material(kind: .image, version: MaterialVersion(fileURL: URL(filePath: "/library/hero.png")))
        let other = Material(kind: .image, version: MaterialVersion(fileURL: URL(filePath: "/library/other.png")))
        let root = folder.appending(path: "Edit In")
        let foreignCopy = root.appending(
            path: "\(other.id.uuidString)_\(other.current.id.uuidString)_abcd1234/other.png")

        #expect(
            OutsideEdit.parent(of: URL(filePath: "/Users/me/Desktop/hero.png"), for: material, root: root)
                == material.reference)
        #expect(OutsideEdit.parent(of: foreignCopy, for: material, root: root) == material.reference)
        #expect(OutsideEdit.source(of: foreignCopy, in: root) == other.reference)
        #expect(OutsideEdit.isOwnFile(URL(filePath: "/library/hero.png"), of: material))
        #expect(!OutsideEdit.isOwnFile(URL(filePath: "/library/other.png"), of: material))
    }

    @Test func theEditIsCopiedBackUnderAFreeName() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let images = folder.appending(path: "Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let edited = folder.appending(path: "hero.png")
        try Data("edited".utf8).write(to: edited)
        try Data("earlier".utf8).write(to: images.appending(path: "hero edited.png"))

        let copy = try OutsideEdit.copyBack(edited, into: images)

        #expect(copy.lastPathComponent == "hero edited 2.png")
        #expect(try Data(contentsOf: copy) == Data("edited".utf8))
        #expect(try Data(contentsOf: images.appending(path: "hero edited.png")) == Data("earlier".utf8))
        #expect(FileManager.default.fileExists(atPath: edited.path))
    }
}
