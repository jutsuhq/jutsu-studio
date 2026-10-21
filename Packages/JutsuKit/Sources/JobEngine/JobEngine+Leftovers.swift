import Foundation
import JutsuCore

extension JobEngine {
    /// Deletes what crashed or abandoned downloads left behind, and upload-cache entries too old to be reused.
    /// Only hidden scratch files (`ScratchFile`) in the output folder and in the folders active jobs download to
    /// are looked at; those of active jobs and running imports stay, and so does every other file.
    /// - Parameter storedIDs: every active job in the repository, including ones that didn't decode.
    func removeLeftovers(activeJobs stored: [Job], storedIDs: Set<UUID>) async {
        let active = stored + jobs.values.filter(\.state.isActive)
        let kept = Set(active.map(\.id)).union(storedIDs).union(runners.keys).union(importing.keys)
        let folders = Set([settings.outputDirectory] + active.compactMap(\.downloadFolder))
        for folder in folders {
            for file in Self.leftovers(in: folder, keeping: kept, isAnyJobRunning: !runners.isEmpty) {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    log.error("Can't delete a leftover scratch file", detail: String(describing: error))
                }
            }
        }
        do {
            try await uploadCache.removeAssets(uploadedBefore: clock.now.addingTimeInterval(-settings.uploadMaxAge))
        } catch {
            log.error("Can't forget old uploads", detail: String(describing: error))
        }
    }

    /// Kept next to the result so the final rename stays on one volume, and across retries and
    /// relaunches so the download resumes.
    static func partialFile(of id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(".\(id.uuidString).partial")
    }

    /// The result with its sound restored, until it is placed.
    static func audioFile(of id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(".\(id.uuidString).audio.mp4")
    }

    /// The regular files in `folder` that `ScratchFile.leftovers` picks; none when it can't be read.
    static func leftovers(in folder: URL, keeping kept: Set<UUID>, isAnyJobRunning: Bool) -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
            ?? []
        let regular = files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let names = Set(
            ScratchFile.leftovers(regular.map(\.lastPathComponent), keeping: kept, isAnyJobRunning: isAnyJobRunning))
        return regular.filter { names.contains($0.lastPathComponent) }
    }
}

/// A hidden file a download writes next to its result. Results never start with a dot (`OutputNamePattern`).
enum ScratchFile: Equatable {
    /// `.<job ID>.partial` and `.<job ID>.audio.mp4` (`JobEngine.partialFile`, `JobEngine.audioFile`).
    case job(UUID)
    /// `.<UUID>.mp4` and `.<UUID>.m4a`, which MediaKit's `AudioRestorer` writes while it runs.
    case unowned

    init?(name: String) {
        guard name.first == ".", let dot = name.dropFirst().firstIndex(of: "."),
            let id = UUID(uuidString: String(name[name.index(after: name.startIndex)..<dot]))
        else { return nil }
        switch name[name.index(after: dot)...] {
        case "partial", "audio.mp4": self = .job(id)
        case "mp4", "m4a": self = .unowned
        default: return nil
        }
    }

    /// The scratch files among `names` that no job can still use: those of jobs not in `kept`, and unowned ones
    /// unless a job runs, since its audio restore may be writing them.
    static func leftovers(_ names: [String], keeping kept: Set<UUID>, isAnyJobRunning: Bool) -> [String] {
        names.filter { name in
            switch ScratchFile(name: name) {
            case .job(let id): !kept.contains(id)
            case .unowned: !isAnyJobRunning
            case nil: false
            }
        }
    }
}
