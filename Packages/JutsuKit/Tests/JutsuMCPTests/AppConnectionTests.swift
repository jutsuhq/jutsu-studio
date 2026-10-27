import Foundation
import JutsuAgent
import Testing

@testable import JutsuMCP

/// Records what the helper asked Launch Services for; it never starts anything.
actor FakeLauncher: AppLauncher {
    var starts: [String] = []
    var activations: [String] = []
    var arguments: [[String]] = []
    /// What a start does: an app that quits at once, so the wait for it ends without sleeping.
    let quits: Bool

    init(quits: Bool = true) { self.quits = quits }

    func start(_ app: URL, bundleID: String, arguments: [String]) async throws -> RunningApp {
        starts.append(bundleID)
        self.arguments.append(arguments)
        let quits = quits
        return RunningApp(launchDate: .now, isTerminated: { quits })
    }

    func activate(bundleID: String) async { activations.append(bundleID) }
}

@Suite struct AppConnectionTests {
    private let home = URL(filePath: "/home/someone", directoryHint: .isDirectory)

    /// A minimal `Jutsu Studio.app` under /tmp with the helper's place in it, its Info.plist naming `group`.
    private func app(group: String?) throws -> URL {
        let app = URL(filePath: "/tmp/jutsu-mcp-\(UUID().uuidString.prefix(8))/Jutsu Studio.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(
            at: contents.appending(path: "Helpers"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.jutsustudio.JutsuStudio", "CFBundlePackageType": "APPL"]
        info[AgentSocket.appGroupKey] = group
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        return app
    }

    /// In a folder of its own, so its inbox is too.
    private func ownSocket() throws -> URL {
        let folder = URL(filePath: "/tmp/jutsu-mcp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: AgentSocket.fileName)
    }

    private func helper(in app: URL) -> URL { app.appending(path: "Contents/Helpers/jutsu") }

    @Test func theOverrideWinsAndNamesTheSocketOutright() {
        let location = AppConnection.locate(
            executable: URL(filePath: "/usr/local/bin/jutsu"), environment: [AgentSocket.variable: "/tmp/dev.sock"],
            home: home)
        #expect(location == .socket(URL(filePath: "/tmp/dev.sock")))
    }

    @Test func aBundledHelperFindsItsAppAndTheGroupsSocket() throws {
        let app = try app(group: "ABCDE12345.com.jutsustudio.jutsustudio")
        let location = AppConnection.locate(executable: helper(in: app), environment: [:], home: home)
        let socket = home.appending(path: "Library/Group Containers/ABCDE12345.com.jutsustudio.jutsustudio/agent.sock")
        guard case .bundled(let found, let bundleID, let foundSocket?) = location else {
            Issue.record("expected the bundled app and its socket, got \(location)")
            return
        }
        let path = { (url: URL) in
            url.resolvingSymlinksInPath().path(percentEncoded: false).trimmingCharacters(in: ["/"])
        }
        #expect(path(found) == path(app))
        #expect(bundleID == "com.jutsustudio.JutsuStudio")
        #expect(foundSocket == socket)
    }

    @Test func anAdHocBuildHasNoSocketAndSaysSo() async throws {
        let app = try app(group: ".com.jutsustudio.jutsustudio")
        let location = AppConnection.locate(executable: helper(in: app), environment: [:], home: home)
        guard case .bundled(_, _, nil) = location else {
            Issue.record("expected no socket, got \(location)")
            return
        }
        let launcher = FakeLauncher()
        let answer = await AppConnection(location: location, launcher: launcher).send(
            .capabilities(CapabilitiesCommand()), client: nil)
        #expect(answer.error?.code == .needsTeamBuild)
        #expect(await launcher.starts.isEmpty)
    }

    @Test func aHelperOutsideAnAppSaysSo() async {
        let location = AppConnection.locate(executable: URL(filePath: "/tmp/jutsu"), environment: [:], home: home)
        #expect(location == .unbundled)
        let answer = await AppConnection(location: location, launcher: FakeLauncher()).send(
            .show(.page(.queue)), client: nil)
        #expect(answer.error?.code == .unbundled)
    }

    @Test func theOverrideNeverStartsTheApp() async {
        let launcher = FakeLauncher()
        let socket = URL(filePath: "/tmp/jutsu-none-\(UUID().uuidString.prefix(8)).sock")
        let answer = await AppConnection(location: .socket(socket), launcher: launcher).send(
            .capabilities(CapabilitiesCommand()), client: nil)
        #expect(answer.error?.code == .notListening)
        #expect(answer.error?.retryable == true)
        #expect(await launcher.starts.isEmpty)
    }

    @Test func aBundledAppThatIsntRunningIsStartedOnce() async {
        let launcher = FakeLauncher(quits: true)
        let socket = URL(filePath: "/tmp/jutsu-none-\(UUID().uuidString.prefix(8)).sock")
        let location = AppConnection.Location.bundled(
            app: URL(filePath: "/Applications/Jutsu Studio.app"), bundleID: "com.jutsustudio.JutsuStudio",
            socket: socket)
        let answer = await AppConnection(location: location, launcher: launcher).send(
            .capabilities(CapabilitiesCommand()), client: nil)
        #expect(answer.error?.code == .notStarted)
        #expect(await launcher.starts == ["com.jutsustudio.JutsuStudio"])
        // With no window and without the focus: the app reads this as a helper launch.
        #expect(await launcher.arguments == [[AgentProtocol.helperLaunchArgument]])
    }

    @Test func aSocketPathTooLongIsRefusedWithoutStartingAnything() async {
        let launcher = FakeLauncher()
        let socket = URL(filePath: "/tmp/" + String(repeating: "x", count: 300))
        let location = AppConnection.Location.bundled(
            app: URL(filePath: "/Applications/Jutsu Studio.app"), bundleID: "com.jutsustudio.JutsuStudio",
            socket: socket)
        let answer = await AppConnection(location: location, launcher: launcher).send(
            .show(.page(.create)), client: nil)
        #expect(answer.error?.code == .socketPathTooLong)
        #expect(await launcher.starts.isEmpty)
    }

    @MainActor
    @Test func aRunningAppAnswersAndShowBringsItForward() async throws {
        let socket = try ownSocket()
        let server = AgentServer(socket: socket, isAllowed: { true }) { request in
            guard case .show(let show) = request.command, let page = show.page else { return AgentResponse() }
            #expect(request.client == "Agent CLI")
            return AgentResponse(shown: AgentShown(page: page))
        }
        try server.start()
        defer { server.stop() }
        let launcher = FakeLauncher()
        let location = AppConnection.Location.bundled(
            app: URL(filePath: "/Applications/Jutsu Studio.app"), bundleID: "com.jutsustudio.JutsuStudio",
            socket: socket)
        let answer = await Task.detached {
            await AppConnection(location: location, launcher: launcher).send(
                .show(.page(.library)), client: "Agent CLI")
        }.value
        #expect(answer.shown == AgentShown(page: .library))
        #expect(await launcher.starts.isEmpty)
        #expect(await launcher.activations == ["com.jutsustudio.JutsuStudio"])
    }

    @MainActor
    @Test func aStagedFileLandsInTheInbox() async throws {
        let socket = try ownSocket()
        let server = AgentServer(socket: socket, isAllowed: { true }) { _ in AgentResponse() }
        try server.start()
        defer { server.stop() }
        let source = URL(filePath: "/tmp/jutsu-mcp-\(UUID().uuidString.prefix(8)).png")
        try Data("png".utf8).write(to: source)
        let connection = AppConnection(location: .socket(socket), launcher: FakeLauncher())
        let path = source.path(percentEncoded: false)
        let staged = try await Task.detached { try await connection.stage(path, for: nil, client: nil) }.value
        #expect(staged.hasPrefix(server.inbox.folder.path(percentEncoded: false)))
        #expect(try Data(contentsOf: URL(filePath: staged)) == Data("png".utf8))
        await #expect(throws: AgentError.self) {
            try await Task.detached { try await connection.stage("/tmp/no-such-file", for: nil, client: nil) }.value
        }
    }
}
