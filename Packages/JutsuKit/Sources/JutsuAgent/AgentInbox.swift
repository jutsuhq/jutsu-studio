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

    /// Moves the finished `partial` to `destination` in one step, refusing with `EEXIST` when anything is there.
    public static func place(_ partial: URL, at destination: URL) throws {
        let moved = renamex_np(
            partial.path(percentEncoded: false), destination.path(percentEncoded: false), UInt32(RENAME_EXCL))
        guard moved == 0 else { throw POSIXError.current }
    }
}
