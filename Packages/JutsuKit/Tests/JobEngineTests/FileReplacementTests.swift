import Foundation
import Testing

@testable import JobEngine

@Suite struct FileReplacementTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Replacement-\(UUID().uuidString)")

    func file(_ name: String, _ contents: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        if let contents { try Data(contents.utf8).write(to: url) }
        return url
    }

    func contents(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func aFileAlreadyThereIsReplaced() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try file("Joined.mp4", "old")
        let finished = try file("scratch", "new")

        try FileReplacement.move(finished, to: target)

        #expect(try contents(of: target) == "new")
        #expect(!FileManager.default.fileExists(atPath: finished.path))
    }

    @Test func aNewNameIsCreated() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try file("Joined.mp4")
        let finished = try file("scratch", "new")

        try FileReplacement.move(finished, to: target)

        #expect(try contents(of: target) == "new")
    }

    @Test func aFailedMoveLeavesTheOldFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try file("Joined.mp4", "old")
        let missing = try file("scratch")

        #expect(throws: (any Error).self) { try FileReplacement.move(missing, to: target) }
        #expect(try contents(of: target) == "old")
    }

    /// An isolated small volume: /dev/shm in Linux CI, or a mounted scratch image on macOS.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JUTSU_REPLACEMENT_TEST_VOLUME"] != nil))
    func aCrossVolumeCopyThatRunsOutOfSpacePreservesTheOldFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let volume = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["JUTSU_REPLACEMENT_TEST_VOLUME"]))
        let destination = volume.appendingPathComponent("Replacement-\(UUID())")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destination) }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: volume.path)
        let free = try #require(attributes[.systemFreeSize] as? NSNumber).uint64Value
        try #require(free < 128 << 20, "Use a small isolated test volume")
        let target = destination.appendingPathComponent("result")
        try Data("old".utf8).write(to: target)
        let source = try file("scratch", "")
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: free + (1 << 20))
        try handle.close()

        #expect(throws: (any Error).self) { try FileReplacement.move(source, to: target) }
        #expect(try contents(of: target) == "old")
        #expect(FileManager.default.fileExists(atPath: source.path))
        try Data("new".utf8).write(to: source)
        try FileReplacement.move(source, to: target)
        #expect(try contents(of: target) == "new")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}
