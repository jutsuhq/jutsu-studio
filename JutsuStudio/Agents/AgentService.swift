import Foundation
import JutsuAgent
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

/// The app's side of agents: the socket the `jutsu` helper talks to, listening from launch, and the commands it runs.
/// Settings › Agents › Allow agents is read for every command, so turning it off refuses the next one at once and
/// stops nothing an agent already started.
@MainActor
@Observable
final class AgentService {
    enum Status: Equatable {
        /// Not started yet, or a smoke test.
        case idle
        case listening(URL)
        /// A build without a team (ad hoc, CI) has no app group, so no socket the helper could find.
        case noAppGroup
        case failed(String)
    }

    private(set) var status = Status.idle

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let system: SystemIntegration
    @ObservationIgnored private let preferences: AgentPreferences
    @ObservationIgnored private var server: AgentServer?

    init(environment: AppEnvironment, system: SystemIntegration, preferences: AgentPreferences = AgentPreferences()) {
        self.environment = environment
        self.system = system
        self.preferences = preferences
    }

    /// Where the socket goes: the app group's container, which the helper finds from the group in Info.plist.
    static var socketURL: URL? {
        #if DEBUG
            // Development only: a release build listens where its signed group says, nowhere else.
            if let path = ProcessInfo.processInfo.environment[AgentSocket.variable], !path.isEmpty {
                return URL(filePath: path)
            }
        #endif
        guard let group = Bundle.main.object(forInfoDictionaryKey: AgentSocket.appGroupKey) as? String,
            AgentSocket.hasTeam(group),
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appending(path: AgentSocket.fileName)
    }

    /// The line Settings › Agents offers to copy, for this copy of the app wherever it is installed.
    static var claudeCommand: String {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/jutsu").path(percentEncoded: false)
        return "claude mcp add jutsu -- \"\(helper)\" mcp"
    }

    func start() {
        guard server == nil else { return }
        guard let socket = Self.socketURL else {
            status = .noAppGroup
            return
        }
        let preferences = preferences
        let server = AgentServer(
            socket: socket, isAllowed: { preferences.isAllowed },
            gate: { _, _ throws(AgentError) in
                // No tool takes files yet; the inbox stays empty until one does and checks its request first.
                throw AgentError(.fileRefused, message: "No tool in this version takes files.", retryable: false)
            },
            handle: { [weak self] request async throws(AgentError) -> AgentResponse in
                guard let self else { throw AgentError.agentsOff }
                return try await self.run(request.command, client: request.client)
            })
        do {
            try server.start()
            self.server = server
            status = .listening(socket)
        } catch {
            logger.error("Can't listen for agents: \(String(describing: error), privacy: .private)")
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func run(_ command: AgentCommand, client: String?) async throws(AgentError) -> AgentResponse {
        switch command {
        case .capabilities(let fields):
            return AgentResponse(capabilities: try capabilities(fields))
        case .show(let fields):
            let shown = try await show(fields)
            logger.info(
                "Agent \(client ?? "unnamed", privacy: .private) showed \(shown.page.rawValue, privacy: .public)")
            return AgentResponse(shown: shown)
        case .upload:
            // The server takes uploads itself; one never reaches the handler.
            throw AgentError.badRequest("upload is sent with its bytes")
        }
    }

    // MARK: Commands

    private func capabilities(_ fields: CapabilitiesCommand) throws(AgentError) -> AgentCapabilities {
        let state = environment.connection.state
        let connection: AgentCapabilities.Connection
        var budget: AgentCapabilities.Budget?
        switch state {
        case .none:
            connection = AgentCapabilities.Connection(kind: .none)
        case .apiKey:
            connection = AgentCapabilities.Connection(kind: .apiKey)
        case .account(let account):
            connection = AgentCapabilities.Connection(kind: .account, plan: account.plan, credits: account.credits)
        }
        if let kind = state.kind {
            // Nothing spends yet, so nothing is taken from the budget.
            budget = AgentCapabilities.Budget(
                unit: kind == .apiKey ? .usdCents : .credits, dailyLimit: preferences.dailyBudget(for: kind),
                spentToday: 0)
        }
        var answer = AgentCapabilities(appVersion: Self.appVersion, connection: connection, budget: budget)
        if fields.models {
            answer.models = try models(fields.model, connection: state.kind)
        }
        return answer
    }

    /// Every model, or the one asked for; whether each runs is what Create last read, never a network call.
    private func models(_ id: String?, connection: ProviderKind?) throws(AgentError) -> [AgentCapabilities.Model] {
        var models = VideoModel.allCases
        if let id {
            guard let model = VideoModel(rawValue: id) else {
                throw AgentError(
                    .notFound, message: "There's no model \(id).", retryable: false,
                    next: "Call capabilities with models true to list them.")
            }
            models = [model]
        }
        let offered = environment.lastOfferedModels
        return models.map { model in
            AgentCapabilities.Model(
                id: model.rawValue, title: model.title, modes: model.modes.map(\.rawValue),
                resolutions: model.resolutions.map(\.rawValue),
                available: connection != nil && offered.contains(model))
        }
    }

    private func show(_ fields: ShowCommand) async throws(AgentError) -> AgentShown {
        let navigation = environment.navigation
        let shown: AgentShown
        if let id = fields.job {
            guard let job = await job(id) else {
                throw AgentError(
                    .notFound, message: "There's no job \(id.uuidString).", retryable: false,
                    next: "Show the queue or the library instead.")
            }
            if job.state == .done {
                navigation.showInLibrary(id)
                shown = AgentShown(page: .library, job: id)
            } else {
                navigation.showInQueue(id)
                shown = AgentShown(page: .queue, job: id)
            }
        } else {
            let page = fields.page ?? .create
            navigation.selection =
                switch page {
                case .create: .create
                case .queue: .queue
                case .library: .library
                case .settings: .settings
                }
            shown = AgentShown(page: page)
        }
        system.showMainWindow()
        return shown
    }

    private func job(_ id: UUID) async -> Job? {
        if let job = environment.liveJobs.job(id) { return job }
        return try? await environment.store.job(id: id)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
