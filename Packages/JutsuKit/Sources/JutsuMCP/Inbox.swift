import Foundation
import JutsuAgent

/// The helper's half of the file handoff (`AgentInbox`): it reads an agent's file and sends its bytes to the app,
/// which stores them in a folder of their own and answers with the copy's path for the command to name.
public struct Inbox: Sendable {
    /// Relative paths are the agent's, from where it started the helper.
    let workingDirectory: URL

    public init(workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    /// The file at `path` and the upload that hands it over, checked before a byte is read.
    public func upload(
        _ path: String, for request: UploadRequest?
    ) throws(AgentError) -> (
        source: URL, command: UploadCommand
    ) {
        let source = Self.resolve(path, from: workingDirectory)
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            throw AgentError(
                .fileRefused, message: "There is no file at \(path).", retryable: false,
                next: "Pass the absolute path of a file on this Mac.")
        }
        let command = UploadCommand(name: source.lastPathComponent, size: Int64(size), request: request)
        if let problem = UploadCommand.problem(name: command.name, size: command.size) {
            throw AgentError(.fileRefused, message: "Jutsu Studio can't take \(path): \(problem).", retryable: false)
        }
        return (source, command)
    }

    static func resolve(_ path: String, from directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(filePath: expanded) : directory.appending(path: expanded)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

extension AppConnection {
    /// Sends the file at `path` into the app's inbox and returns where the app put it. Safe to repeat: each upload
    /// lands in a new folder, so a retry never touches an earlier copy.
    public func stage(_ path: String, for request: UploadRequest?, client: String?) async throws(AgentError) -> String {
        let (source, command) = try Inbox().upload(path, for: request)
        let timeout = timeout
        let response = await exchange { socket in
            try AgentClient(socket: socket, timeout: timeout).upload(command, from: source, client: client)
        }
        if let error = response.error { throw error }
        guard let uploaded = response.uploaded else {
            throw AgentError(
                .fileRefused, message: "Jutsu Studio didn't take \(path).", retryable: true,
                next: "Update Jutsu Studio so the app and this helper match, then send the request again.")
        }
        return uploaded
    }
}
