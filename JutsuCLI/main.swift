import Foundation
import JutsuAgent
import JutsuMCP

// The helper agents run, bundled at Jutsu Studio.app/Contents/Helpers/jutsu (project.yml). Not sandboxed: it drives
// the sandboxed app through the agent socket in their shared app group's container. stdout carries MCP messages only;
// anything for a person goes to stderr.

let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
let location = AppConnection.locate(
    executable: executable, environment: ProcessInfo.processInfo.environment, home: .homeDirectory)
// The Info.plist built into this binary (project.yml) carries the app's version.
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"

let usage = """
    Usage: jutsu mcp
           jutsu --help | --version

    Lets an AI agent drive Jutsu Studio on this Mac.

      mcp         A Model Context Protocol server on stdin and stdout. Add it to
                  Claude Code with:
                    claude mcp add jutsu -- "/Applications/Jutsu Studio.app/Contents/Helpers/jutsu" mcp
      --version   The version of the app this helper is bundled in.
      -h, --help  Show this help.

    The app answers only while Settings › Agents › Allow agents is on. When it isn't
    running, the first call starts it in the background.

    Environment:
      \(AgentSocket.variable)  The socket to use instead of the bundled app's, for
                          development. The app is never started for it.
    """

switch CommandLine.arguments.dropFirst().first {
case "mcp":
    let connection = AppConnection(location: location, launcher: WorkspaceLauncher())
    var server = MCPServer(
        version: version,
        stage: { path, request, client in
            do throws(AgentError) {
                return .success(try await connection.stage(path, for: request, client: client))
            } catch {
                return .failure(error)
            }
        },
        send: { await connection.send($0, client: $1) })
    // One JSON-RPC message per line until the client closes stdin.
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let reply = await server.reply(to: Data(line.utf8)) else { continue }
        FileHandle.standardOutput.write(reply)
    }
case "-h", "--help":
    FileHandle.standardOutput.write(Data((usage + "\n").utf8))
case "--version":
    FileHandle.standardOutput.write(Data((version + "\n").utf8))
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}
