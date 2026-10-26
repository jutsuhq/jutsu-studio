import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

@Suite struct ScratchFileTests {
    let kept = UUID()
    let gone = UUID()

    @Test func onlyScratchNamesOfInactiveJobsAreLeftovers() {
        let names = [
            ".\(kept.uuidString).partial", ".\(kept.uuidString).audio.mp4",
            ".\(gone.uuidString).partial", ".\(gone.uuidString).audio.mp4",
            "2026-03-07_restyle_1a2b3c4d.mp4", "\(gone.uuidString).partial", ".\(gone.uuidString).partial.mp4",
            ".\(gone.uuidString).mov", ".not-a-uuid.partial", ".DS_Store", ".", "",
        ]
        #expect(
            ScratchFile.leftovers(names, keeping: [kept], isAnyJobRunning: true)
                == [".\(gone.uuidString).partial", ".\(gone.uuidString).audio.mp4"])
    }

    @Test func unownedAudioScratchStaysWhileAJobRuns() {
        let names = [".\(UUID().uuidString).mp4", ".\(UUID().uuidString).m4a"]
        #expect(ScratchFile.leftovers(names, keeping: [], isAnyJobRunning: true).isEmpty)
        #expect(ScratchFile.leftovers(names, keeping: [], isAnyJobRunning: false) == names)
    }

    @Test func engineNamesParseAsTheirJob() {
        let folder = URL(fileURLWithPath: "/output")
        #expect(ScratchFile(name: JobEngine.partialFile(of: kept, in: folder).lastPathComponent) == .job(kept))
        #expect(ScratchFile(name: JobEngine.audioFile(of: kept, in: folder).lastPathComponent) == .job(kept))
    }

    /// Enhance on this Mac writes `.ondevice-<UUID>.partial` and clears its own; the sweep leaves a running one be.
    @Test func onDevicePartialsAreNotAJobs() {
        let name = ".ondevice-\(UUID().uuidString).partial"
        #expect(ScratchFile(name: name) == nil)
        #expect(ScratchFile.leftovers([name], keeping: [], isAnyJobRunning: false).isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LeftoverCleanupTests {
    private func write(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data("vid".utf8).write(to: file)
        return file
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func startDeletesOnlyScratchFilesNoActiveJobOwns() async throws {
        let harness = Harness()
        let otherFolder = harness.outputDirectory.appendingPathComponent("earlier-folder")
        defer { try? FileManager.default.removeItem(at: harness.outputDirectory) }
        let output = harness.outputDirectory
        var paused = storedJob(owner: "key-a", state: .paused(.byUser))
        paused.downloadFolder = otherFolder
        var finished = storedJob(owner: "key-a", state: .done)
        let result = try write("2026-03-07_motionTransfer_1a2b3c4d.mp4", in: output)
        finished.outputFile = result
        await harness.repository.save(paused)
        await harness.repository.save(finished)

        let pausedPartial = try write(".\(paused.id.uuidString).partial", in: otherFolder)
        let pausedAudio = try write(".\(paused.id.uuidString).audio.mp4", in: otherFolder)
        let userFiles = try [
            write(".hidden-by-the-user.mp4", in: output), write("notes.partial", in: output),
            write("\(finished.id.uuidString).partial", in: output),
        ]
        let leftovers = try [
            write(".\(finished.id.uuidString).partial", in: output),
            write(".\(UUID().uuidString).partial", in: output),
            write(".\(UUID().uuidString).audio.mp4", in: otherFolder),
            write(".\(UUID().uuidString).mp4", in: output), write(".\(UUID().uuidString).m4a", in: otherFolder),
        ]
        let scratchNamedFolder = output.appendingPathComponent(".\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(at: scratchNamedFolder, withIntermediateDirectories: true)

        _ = try await harness.makeEngine()

        #expect(leftovers.allSatisfy { !exists($0) })
        #expect(exists(result))
        #expect(exists(pausedPartial) && exists(pausedAudio))
        #expect(userFiles.allSatisfy(exists))
        #expect(exists(scratchNamedFolder))
    }

    @Test func startKeepsScratchFilesOfARecordThatDidNotDecode() async throws {
        let harness = Harness()
        defer { try? FileManager.default.removeItem(at: harness.outputDirectory) }
        let unreadable = UUID()
        await harness.repository.saveUndecodable(id: unreadable)
        let partial = try write(".\(unreadable.uuidString).partial", in: harness.outputDirectory)
        let audio = try write(".\(unreadable.uuidString).audio.mp4", in: harness.outputDirectory)
        let abandoned = try write(".\(UUID().uuidString).partial", in: harness.outputDirectory)

        _ = try await harness.makeEngine()

        #expect(exists(partial) && exists(audio))
        #expect(!exists(abandoned))
    }

    @Test func aResumedDownloadKeepsItsPartialFile() async throws {
        let harness = Harness(download: .hangOnce)
        defer { try? FileManager.default.removeItem(at: harness.outputDirectory) }
        let first = try await harness.makeEngine()
        let job = try await first.enqueue(makeSpec())
        await harness.repository.wait(for: job.id, .downloading)
        await eventually { harness.downloader.starts.all.count == 1 }
        let partial = await first.partialDownload(of: job.id)
        await eventually { (try? Data(contentsOf: partial)) == Data("vid".utf8) }
        await first.stop()

        _ = try await harness.makeEngine()
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(harness.downloader.starts.all == ["0", "3"])
        let output = try #require(done.outputFile)
        #expect(try Data(contentsOf: output) == Data("video".utf8))
    }

    @Test func startForgetsUploadsTooOldToReuse() async throws {
        let harness = Harness()
        let asset = RemoteAsset(url: URL(string: "https://upload.example/a")!)
        await harness.cache.store(asset, contentHash: "fresh", uploadedAt: harness.clock.now - 3600)
        await harness.cache.store(asset, contentHash: "stale", uploadedAt: harness.clock.now - 3601)

        _ = try await harness.makeEngine()

        #expect(await harness.cache.contentHashes == ["fresh"])
    }
}
