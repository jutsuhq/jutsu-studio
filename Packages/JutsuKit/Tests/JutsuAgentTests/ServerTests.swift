import Darwin
import Foundation
import JutsuTestSupport
import Testing

@testable import JutsuAgent

/// A short socket path of its own under /tmp, or one `length` bytes long.
func temporarySocket(length: Int? = nil) throws -> URL {
    var folder = URL(filePath: "/tmp/jutsu-agent-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    if let length {
        let padding = length - folder.path(percentEncoded: false).utf8.count - "/agent.sock".utf8.count - 1
        folder = folder.appending(path: String(repeating: "d", count: max(1, padding)), directoryHint: .isDirectory)
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: AgentSocket.fileName)
}

/// Runs `body` with a client off the main actor: the server answers there, and the client blocks.
func exchange<T: Sendable>(_ socket: URL, _ body: @escaping @Sendable (AgentClient) throws -> T) async throws -> T {
    try await Task.detached {
        try body(try AgentClient(socket: socket, timeout: .seconds(5)))
    }.value
}

/// Allow agents as a test flips it from the client's thread while the server reads it on the main actor.
/// `@unchecked Sendable`: both properties are only touched under `lock`.
final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    private var count = 0

    init(_ isOn: Bool) { on = isOn }

    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }

    var handled: Int { lock.withLock { count } }
    func handle() { lock.withLock { count += 1 } }
}

@MainActor
@Suite struct ServerTests {
    private let capabilities = AgentCapabilities(
        appVersion: "1.0", connection: .init(kind: .none), budget: nil)

    private func server(_ allowed: Switch, gate: @escaping AgentServer.UploadGate = { _, _ in }) throws -> AgentServer {
        let capabilities = capabilities
        let server = AgentServer(socket: try temporarySocket(), isAllowed: { allowed.isOn }, gate: gate) { request in
            allowed.handle()
            return AgentResponse(capabilities: capabilities)
        }
        try server.start()
        return server
    }

    @Test func everyCommandIsRefusedWhileAgentsAreOffEvenOnAnOpenConnection() async throws {
        let allowed = Switch(false)
        let server = try server(allowed)
        defer { server.stop() }
        let request = AgentRequest(.capabilities(CapabilitiesCommand()), id: "1")
        let (off, on, offAgain) = try await exchange(server.socket) { client in
            let off = try client.send(request)
            allowed.isOn = true
            let on = try client.send(request)
            allowed.isOn = false
            return (off, on, try client.send(request))
        }
        #expect(off.error?.code == .agentsOff)
        #expect(off.error?.retryable == true)
        #expect(off.id == "1")
        #expect(on.capabilities == capabilities)
        #expect(offAgain.error == .agentsOff)
        #expect(allowed.handled == 1)
    }

    @Test func aMalformedLineGetsAnErrorAndTheConnectionStaysUsable() async throws {
        let server = try server(Switch(true))
        defer { server.stop() }
        let (bad, good) = try await exchange(server.socket) { client in
            (try client.send(line: Data("{nope\n".utf8)), try client.send(AgentRequest(.show(.page(.library)))))
        }
        #expect(bad.error?.code == .badRequest)
        #expect(good.capabilities != nil)
    }

    /// A command whose work outlasts the answer deadline answers `still_working`, and the work goes on to finish.
    @Test func aSlowCommandAnswersStillWorkingAndKeepsRunning() async throws {
        let finished = Switch(false)
        let release = AsyncStream<Void>.makeStream()
        let server = AgentServer(socket: try temporarySocket(), isAllowed: { true }, answerDeadline: .milliseconds(20))
        {
            _ in
            for await _ in release.stream { break }
            finished.isOn = true
            return AgentResponse(shown: AgentShown(page: .queue))
        }
        try server.start()
        defer { server.stop() }
        let answer = try await exchange(server.socket) { try $0.send(AgentRequest(.show(.page(.queue)), id: "7")) }
        #expect(answer.error?.code == .stillWorking)
        #expect(answer.error?.retryable == true)
        #expect(answer.id == "7")
        #expect(!finished.isOn)
        release.continuation.yield()
        await eventually { finished.isOn }
        #expect(finished.isOn)
    }

    @Test func theHelperWaitsLongerThanTheAppTakesToAnswer() {
        #expect(AgentProtocol.answerDeadline <= .seconds(60))
        #expect(AgentProtocol.helperTimeout > AgentProtocol.answerDeadline)
    }

    @Test func theSocketIsTheUsersAlone() throws {
        let server = try server(Switch(true))
        defer { server.stop() }
        var info = stat()
        #expect(stat(server.socket.path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func aSocketPastTheShortAddressStillWorks() async throws {
        let socket = try temporarySocket(length: 200)
        #expect(socket.path(percentEncoded: false).utf8.count > 104)
        let server = AgentServer(socket: socket, isAllowed: { true }) { _ in
            AgentResponse(shown: AgentShown(page: .queue))
        }
        try server.start()
        defer { server.stop() }
        let answer = try await exchange(socket) { try $0.send(AgentRequest(.show(.page(.queue)))) }
        #expect(answer.shown == AgentShown(page: .queue))
    }

    @Test func aSocketPathTooLongIsRefusedByBothEnds() throws {
        let socket = URL(filePath: "/tmp/" + String(repeating: "x", count: AgentSocket.maxPathLength))
        #expect(!AgentSocket.fits(socket))
        #expect(AgentSocket.withAddress(socket) { _, _ in true } == nil)
        let server = AgentServer(socket: socket, isAllowed: { true }) { _ in AgentResponse() }
        #expect(throws: AgentError.socketPathTooLong(socket)) { try server.start() }
        #expect(throws: AgentClient.Failure.pathTooLong) { try AgentClient(socket: socket) }
    }

    @Test func nothingListeningIsNotListening() throws {
        let socket = try temporarySocket()
        #expect(throws: AgentClient.Failure.notListening(errno: ENOENT)) { try AgentClient(socket: socket) }
    }

    // MARK: Inbox

    private func file(_ text: String) throws -> URL {
        let url = try temporarySocket().deletingLastPathComponent().appending(path: "clip.mov")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func uploadsOfOneNameNeverReplaceEachOther() async throws {
        let server = try server(Switch(true))
        defer { server.stop() }
        let first = try file("first")
        let second = try file("second, longer")
        let socket = server.socket
        let answers = try await exchange(socket) { client in
            [
                try client.upload(UploadCommand(name: "clip.mov", size: 5), from: first),
                try client.upload(UploadCommand(name: "clip.mov", size: 14), from: second),
            ]
        }
        let paths = try answers.map { try #require($0.uploaded) }
        #expect(Set(paths).count == 2)
        #expect(paths.allSatisfy { $0.hasPrefix(server.inbox.folder.path(percentEncoded: false)) })
        #expect(try String(contentsOfFile: paths[0], encoding: .utf8) == "first")
        #expect(try String(contentsOfFile: paths[1], encoding: .utf8) == "second, longer")
        // Nothing half-written is left beside them.
        let folder = URL(filePath: paths[0]).deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == ["clip.mov"])
    }

    @Test func aRefusedUploadReadsNoBytesAndStagesNothing() async throws {
        let allowed = Switch(true)
        let server = try server(allowed) { _, _ throws(AgentError) in
            throw AgentError(.requestConflict, message: "taken", retryable: false)
        }
        defer { server.stop() }
        let source = try file("bytes")
        let refused = try await exchange(server.socket) {
            try $0.upload(UploadCommand(name: "clip.mov", size: 5), from: source)
        }
        #expect(refused.error?.code == .requestConflict)
        allowed.isOn = false
        let off = try await exchange(server.socket) {
            try $0.upload(UploadCommand(name: "clip.mov", size: 5), from: source)
        }
        #expect(off.error == .agentsOff)
        let inbox = server.inbox.folder.path(percentEncoded: false)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: inbox)) ?? [] == [])
    }

    /// An upload must leave about 2 GB free on the volume and keep the inbox within 8 GiB; an unknown free space
    /// refuses nothing.
    @Test func anUploadNeedsRoomOnTheVolumeAndInTheInbox() {
        let size: Int64 = 1 << 30
        let room = AgentInbox.minFreeSpace + size
        #expect(AgentInbox.roomProblem(size: size, freeSpace: room, stored: 0) == nil)
        #expect(AgentInbox.roomProblem(size: size, freeSpace: nil, stored: 0) == nil)
        #expect(AgentInbox.roomProblem(size: size, freeSpace: room - 1, stored: 0) != nil)
        #expect(AgentInbox.roomProblem(size: size, freeSpace: room, stored: AgentInbox.maxStoredSize - size) == nil)
        #expect(AgentInbox.roomProblem(size: size, freeSpace: room, stored: AgentInbox.maxStoredSize - size + 1) != nil)
    }

    @Test func anUploadWithoutRoomIsRefusedForGood() async throws {
        let server = AgentServer(socket: try temporarySocket(), isAllowed: { true }, freeSpace: { _ in 1 << 30 }) { _ in
            AgentResponse()
        }
        try server.start()
        defer { server.stop() }
        let source = try file("bytes")
        let refused = try await exchange(server.socket) {
            try $0.upload(UploadCommand(name: "clip.mov", size: 5), from: source)
        }
        #expect(refused.error?.code == .fileRefused)
        #expect(refused.error?.retryable == false)
        let inbox = server.inbox.folder.path(percentEncoded: false)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: inbox)) ?? [] == [])
    }

    @Test func theInboxCountsWhatItsUploadsHold() throws {
        let inbox = AgentInbox(socket: try temporarySocket())
        #expect(inbox.storedSize() == 0)
        try Data(count: 3).write(to: try inbox.makeUploadFolder().appending(path: "a.png"))
        try Data(count: 5).write(to: try inbox.makeUploadFolder().appending(path: ".partial"))
        #expect(inbox.storedSize() == 8)
    }

    @Test func placingAFileNeverReplacesOne() throws {
        let inbox = AgentInbox(socket: try temporarySocket())
        let folder = try inbox.makeUploadFolder()
        #expect(try inbox.makeUploadFolder() != folder)
        let staged = folder.appending(path: "clip.mov")
        try Data("kept".utf8).write(to: staged)
        let partial = folder.appending(path: ".partial")
        try Data("new".utf8).write(to: partial)
        #expect(throws: POSIXError(.EEXIST)) { try AgentInbox.place(partial, at: staged) }
        #expect(try String(contentsOf: staged, encoding: .utf8) == "kept")
    }
}
