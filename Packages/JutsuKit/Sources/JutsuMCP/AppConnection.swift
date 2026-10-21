import Foundation
import JutsuAgent

/// Starts the app and brings it forward: Launch Services, which only the helper's own target may use (AppKit stays
/// out of the packages). Tests pass one that records its calls.
public protocol AppLauncher: Sendable {
    /// The app with `bundleID` when it is running already, else the one at `app` started in the background, without
    /// activating it.
    func start(_ app: URL, bundleID: String) async throws -> RunningApp
    /// Brings the running app forward after `show`.
    func activate(bundleID: String) async
}

/// A started or running app, as far as the helper needs to follow it.
public struct RunningApp: Sendable {
    public var launchDate: Date
    public var isTerminated: @Sendable () -> Bool

    public init(launchDate: Date, isTerminated: @escaping @Sendable () -> Bool) {
        self.launchDate = launchDate
        self.isTerminated = isTerminated
    }
}

/// How the helper reaches the app. It keeps no state: every command opens the socket, sends one request and closes
/// it. When nothing answers, it starts the app it is bundled in, in the background, and waits a bounded time for it.
public struct AppConnection: Sendable {
    public enum Location: Equatable, Sendable {
        /// Inside Jutsu Studio.app (`Contents/Helpers/jutsu`): the app to start and the socket in its app group's
        /// container; nil for a build signed without a team, which has no socket.
        case bundled(app: URL, bundleID: String, socket: URL?)
        /// A socket named outright (`JUTSU_AGENT_SOCKET`), for development. Nothing is ever started for it.
        case socket(URL)
        /// Neither: this binary isn't inside an app and no socket was named.
        case unbundled

        var socket: URL? {
            switch self {
            case .bundled(_, _, let socket): socket
            case .socket(let socket): socket
            case .unbundled: nil
            }
        }
    }

    public let location: Location
    let launcher: any AppLauncher
    /// How long a starting app has to begin answering, counted from its launch.
    var launchWait: Duration = .seconds(10)
    /// How long one command may wait for its answer: the app answers every one within `AgentProtocol.answerDeadline`
    /// (a `jobs` or export wait included), so no tool call blocks longer than this.
    var timeout = AgentProtocol.helperTimeout

    public init(location: Location, launcher: any AppLauncher) {
        self.location = location
        self.launcher = launcher
    }

    /// Where `executable` (symlinks resolved) finds the app: the override, else the bundle two levels up whose
    /// Info.plist names the app group.
    public static func locate(executable: URL, environment: [String: String], home: URL) -> Location {
        if let path = environment[AgentSocket.variable], !path.isEmpty {
            return .socket(URL(filePath: (path as NSString).expandingTildeInPath))
        }
        let app = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app), let bundleID = bundle.bundleIdentifier,
            let group = bundle.object(forInfoDictionaryKey: AgentSocket.appGroupKey) as? String
        else { return .unbundled }
        let socket = AgentSocket.hasTeam(group) ? AgentSocket.groupSocket(group, home: home) : nil
        return .bundled(app: app, bundleID: bundleID, socket: socket)
    }

    /// Sends `command` and returns the app's answer, or an error saying why the app couldn't be reached.
    public func send(_ command: AgentCommand, client: String?) async -> AgentResponse {
        let timeout = timeout
        let response = await exchange { socket in
            try AgentClient(socket: socket, timeout: timeout).send(
                AgentRequest(command, id: UUID().uuidString, client: client))
        }
        if case .show = command, case .bundled(_, let bundleID, _) = location, response.shown != nil {
            await launcher.activate(bundleID: bundleID)
        }
        return response
    }

    /// One round trip through the socket, `body` making it, starting the bundled app when nothing answers. `body`
    /// blocks its thread on the socket, so it runs on one of its own (`blocking`): the helper serves requests at once.
    func exchange(_ body: @escaping @Sendable (URL) throws -> AgentResponse) async -> AgentResponse {
        switch location {
        case .unbundled:
            return AgentResponse(error: .unbundled)
        case .bundled(_, _, nil):
            return AgentResponse(error: .needsTeamBuild)
        case .socket(let socket), .bundled(_, _, let socket?):
            // The app can't listen there either, so starting it and waiting would only end in a misleading timeout.
            guard AgentSocket.fits(socket) else { return AgentResponse(error: .socketPathTooLong(socket)) }
            do {
                return try await Self.blocking(body, socket)
            } catch AgentClient.Failure.notListening {
                guard case .bundled(let app, let bundleID, _) = location else {
                    return AgentResponse(error: .notListening(socket))
                }
                return await startAndSend(body, app: app, bundleID: bundleID, socket: socket)
            } catch {
                return AgentResponse(error: .lostAnswer)
            }
        }
    }

    /// Nothing listens: the app isn't running or is still starting. A running app that doesn't answer within
    /// `launchWait` of its launch couldn't open the socket, and Settings › Agents says why.
    private func startAndSend(
        _ body: @escaping @Sendable (URL) throws -> AgentResponse, app: URL, bundleID: String, socket: URL
    ) async -> AgentResponse {
        let running: RunningApp
        do {
            running = try await launcher.start(app, bundleID: bundleID)
        } catch {
            return AgentResponse(error: .notStarted(app, reason: error.localizedDescription))
        }
        let deadline = running.launchDate.addingTimeInterval(TimeInterval(launchWait.components.seconds))
        while true {
            do {
                return try await Self.blocking(body, socket)
            } catch AgentClient.Failure.notListening {
                // Not yet.
            } catch {
                return AgentResponse(error: .lostAnswer)
            }
            if running.isTerminated() { return AgentResponse(error: .notStarted(app, reason: "it quit")) }
            if Date.now >= deadline { return AgentResponse(error: .notListening(socket)) }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Runs `body` on a thread of Dispatch's, not one of the few threads every task shares, which a few waits on the
    /// app would otherwise all hold.
    private static func blocking(
        _ body: @escaping @Sendable (URL) throws -> AgentResponse, _ socket: URL
    ) async throws -> AgentResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try body(socket) }) }
        }
    }
}

extension AgentError.Code {
    public static let notListening = Self(rawValue: "not_listening")
    public static let notStarted = Self(rawValue: "app_not_started")
    public static let needsTeamBuild = Self(rawValue: "needs_team_build")
    public static let unbundled = Self(rawValue: "not_in_app")
    public static let lostAnswer = Self(rawValue: "no_answer")
}

extension AgentError {
    static func notListening(_ socket: URL) -> AgentError {
        AgentError(
            .notListening,
            message: "Jutsu Studio doesn't answer at \(socket.path(percentEncoded: false)).", retryable: true,
            next: "Ask the person to open Jutsu Studio and check Settings › Agents, then send the request again.")
    }

    static func notStarted(_ app: URL, reason: String) -> AgentError {
        AgentError(
            .notStarted, message: "Couldn't start \(app.path(percentEncoded: false)): \(reason).", retryable: true,
            next: "Ask the person to open Jutsu Studio, then send the request again.")
    }

    static let needsTeamBuild = AgentError(
        .needsTeamBuild,
        message: "This Jutsu Studio build is signed without a team ID, so it has no agent socket.", retryable: false,
        next: "Use a release of Jutsu Studio, or a build signed with DEVELOPMENT_TEAM; for development, point "
            + "\(AgentSocket.variable) at a socket.")

    static let unbundled = AgentError(
        .unbundled, message: "This jutsu binary isn't inside Jutsu Studio.app.", retryable: false,
        next: "Run the one at Jutsu Studio.app/Contents/Helpers/jutsu, or point \(AgentSocket.variable) at a socket.")

    /// The request went out but no answer came back: the app quit, or took longer than the timeout.
    static let lostAnswer = AgentError(
        .lostAnswer, message: "Jutsu Studio didn't answer the request.", retryable: true,
        next: "Call capabilities to check that the app is running, then send the request again.")
}
