import Darwin
import Foundation

/// Where files from agents wait until the command that names them takes them: `inbox/` next to the socket, in the app
/// group's container. The sandboxed app may not open an agent's paths, and macOS keeps the helper out of the group
/// container (App Data protection: its writes there fail with EPERM, without a prompt), so the helper sends each
/// file's bytes over the socket (`UploadCommand`) and the app writes them here itself.
///
/// Nothing staged is ever replaced. Every upload gets a folder of its own, `inbox/<UUID>/`, made by this call and no
/// other, and its file is moved in only where nothing is yet (`RENAME_EXCL`). A repeated request, or one refused
/// later for a conflicting `request_id`, can't change a file a waiting job still reads.
public struct AgentInbox: Sendable {
    public static let folderName = "inbox"
    /// The largest file an agent can hand over: 4 GiB, a long 4K source video. Each one is a full copy while it waits.
    public static let maxFileSize: Int64 = 4 << 30

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// The inbox next to `socket`.
    public init(socket: URL) {
        folder = socket.deletingLastPathComponent().appending(path: Self.folderName, directoryHint: .isDirectory)
    }

    /// A new, empty folder for one upload. `mkdir` fails on an existing name, so a folder is never shared even if
    /// two UUIDs ever met; it then tries another.
    public func makeUploadFolder() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for _ in 0..<3 {
            let candidate = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            if mkdir(candidate.path(percentEncoded: false), 0o700) == 0 { return candidate }
            guard errno == EEXIST else { throw POSIXError.current }
        }
        throw POSIXError(.EEXIST)
    }

    /// The upload folder `path` is in, when it is one of this inbox's: `inbox/<UUID>/name`, nothing else.
    public func uploadFolder(of path: String) -> URL? {
        let file = URL(filePath: path).standardizedFileURL
        let folder = file.deletingLastPathComponent()
        guard UUID(uuidString: folder.lastPathComponent) != nil,
            folder.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
                == self.folder.standardizedFileURL.path(percentEncoded: false)
        else { return nil }
        return folder
    }

    /// Removes the upload folders of `paths`, the files of a request that was refused or never queued.
    public func remove(_ paths: [String]) {
        for folder in Set(paths.compactMap(uploadFolder(of:))) { try? FileManager.default.removeItem(at: folder) }
    }

    /// Removes the upload folders last changed before `cutoff` that hold none of `kept`, the files jobs still read.
    /// Returns how many it removed. A folder whose date can't be read stays.
    @discardableResult
    public func sweep(keeping kept: Set<String>, before cutoff: Date) -> Int {
        let keptFolders = Set(kept.compactMap(uploadFolder(of:)).map { $0.lastPathComponent })
        guard
            let folders = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        var removed = 0
        for candidate in folders where UUID(uuidString: candidate.lastPathComponent) != nil {
            guard !keptFolders.contains(candidate.lastPathComponent),
                let date = try? candidate.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                date < cutoff
            else { continue }
            if (try? FileManager.default.removeItem(at: candidate)) != nil { removed += 1 }
        }
        return removed
    }

    /// Moves the finished `partial` to `destination` in one step, refusing with `EEXIST` when anything is there.
    public static func place(_ partial: URL, at destination: URL) throws {
        let moved = renamex_np(
            partial.path(percentEncoded: false), destination.path(percentEncoded: false), UInt32(RENAME_EXCL))
        guard moved == 0 else { throw POSIXError.current }
    }
}
