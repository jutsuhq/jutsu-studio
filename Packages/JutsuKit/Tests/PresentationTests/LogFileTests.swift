import Foundation
import JutsuCore
import Testing

@testable import Presentation

@MainActor
@Suite struct LogFileTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LogFileTests-\(UUID())")

    func record(_ id: String) -> ImageJobRecord {
        ImageJobRecord(
            job: RemoteJob(requestID: id), owner: "user_1", runID: UUID(), createdAt: Date(timeIntervalSince1970: 0),
            prompt: "a knight", model: "soul", aspectRatio: nil, count: 1)
    }

    var asideFiles: [URL] {
        get throws {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("\(ImageJobLog.fileName).unreadable-") }
        }
    }

    /// A record that can't be read (a newer version's, say) leaves the others, and the next write keeps it aside
    /// instead of erasing it: it may be a paid job.
    @Test func anUnreadableRecordLeavesTheOthersAndIsKeptAside() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        ImageJobLog(folder: folder).add([record("job-1")])
        let url = folder.appending(path: ImageJobLog.fileName)
        var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
        records.append(["job": "from a newer version"])
        try JSONSerialization.data(withJSONObject: records).write(to: url)

        let log = ImageJobLog(folder: folder)
        #expect(log.records.map(\.id) == ["job-1"])
        log.add([record("job-2")])

        #expect(ImageJobLog(folder: folder).records.map(\.id) == ["job-1", "job-2"])
        let aside = try #require(try asideFiles.first)
        #expect(try String(contentsOf: aside, encoding: .utf8).contains("from a newer version"))
    }

    @Test func aFileThatIsntJSONIsKeptAside() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appending(path: ImageJobLog.fileName))

        let log = ImageJobLog(folder: folder)
        #expect(log.records.isEmpty)
        log.add([record("job-1")])

        #expect(ImageJobLog(folder: folder).records.map(\.id) == ["job-1"])
        #expect(try asideFiles.map { try String(contentsOf: $0, encoding: .utf8) } == ["not json"])
    }
}
