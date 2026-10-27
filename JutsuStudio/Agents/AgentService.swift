import Foundation
import JobEngine
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

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let system: SystemIntegration
    @ObservationIgnored let preferences: AgentPreferences
    @ObservationIgnored var server: AgentServer?
    /// The paid requests, `create_video`, `create_image` and `enhance`, each run once for its request ID.
    @ObservationIgnored let requests: AgentRequestGate<AgentCreated, AgentError>
    /// The exports agents started, followed with `jobs`; in memory, so a relaunch forgets them.
    @ObservationIgnored let operations = AgentOperations()
    /// The Enhance runs on this Mac agents started, followed with `jobs`; in memory too.
    @ObservationIgnored let onDeviceAgent: AgentOnDeviceRuns
    /// The subtitles runs agents started, followed with `jobs` as on-device runs; in memory too.
    @ObservationIgnored let subtitleAgent: AgentSubtitleRuns

    init(environment: AppEnvironment, system: SystemIntegration, preferences: AgentPreferences = AgentPreferences()) {
        self.environment = environment
        self.system = system
        self.preferences = preferences
        requests = AgentRequestGate(log: environment.agentRequests)
        let priceUnit = { @MainActor in environment.connection.state.kind.map(AgentBudgetUnit.init(for:)) ?? .usdCents }
        onDeviceAgent = AgentOnDeviceRuns(runs: environment.onDevice, priceUnit: priceUnit)
        subtitleAgent = AgentSubtitleRuns(
            runs: environment.subtitles, models: environment.speechModels, priceUnit: priceUnit)
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
            gate: { [weak self] upload, _ throws(AgentError) in
                guard let self else { throw AgentError.agentsOff }
                try self.admit(upload)
            },
            freeSpace: URLSessionDownloader.freeSpace(for:),
            handle: { [weak self] request async throws(AgentError) -> AgentResponse in
                guard let self else { throw AgentError.agentsOff }
                return try await self.run(request.command, client: request.client)
            })
        do {
            try server.start()
            self.server = server
            status = .listening(socket)
            Task { await sweepInbox() }
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
            return AgentResponse(capabilities: try await capabilities(fields))
        case .show(let fields):
            let shown = try await show(fields)
            logger.info(
                "Agent \(client ?? "unnamed", privacy: .private) showed \(shown.page.rawValue, privacy: .public)")
            return AgentResponse(shown: shown)
        case .upload:
            // The server takes uploads itself; one never reaches the handler.
            throw AgentError.badRequest("upload is sent with its bytes")
        case .quote(let fields):
            return AgentResponse(quote: try await quote(fields))
        case .createVideo(let fields):
            let created = try await createVideo(fields, client: client)
            logger.info(
                "Agent \(client ?? "unnamed", privacy: .private) queued \(created.jobs.count, privacy: .public) job(s), known: \(created.known, privacy: .private)"
            )
            return AgentResponse(created: created)
        case .jobs(let fields):
            return AgentResponse(jobs: try await jobs(fields))
        case .jobAction(let fields):
            let acted = try await act(fields)
            logger.info(
                "Agent \(client ?? "unnamed", privacy: .private) ran \(fields.action.rawValue, privacy: .public)")
            return AgentResponse(acted: acted)
        case .createImage(let fields):
            return AgentResponse(created: try await createImage(fields, client: client))
        case .librarySearch(let fields):
            return AgentResponse(library: try await librarySearch(fields))
        case .libraryGet(let fields):
            return AgentResponse(details: try await libraryGet(fields))
        case .elements(let fields):
            return AgentResponse(elements: try await elements(fields))
        case .libraryDownload(let fields):
            return AgentResponse(downloads: try await libraryDownload(fields))
        case .libraryMark(let fields):
            let marked = try await libraryMark(fields)
            logger.info("Agent \(client ?? "unnamed", privacy: .private) marked \(marked.changed, privacy: .private)")
            return AgentResponse(marked: marked)
        case .enhance(let fields):
            return AgentResponse(created: try await enhance(fields, client: client))
        case .deliverySet(let fields):
            return AgentResponse(delivery: try await deliverySet(fields))
        case .export(let fields):
            return AgentResponse(exported: try await exportForEditing(fields))
        case .frames(let fields):
            return AgentResponse(frames: try await frames(fields))
        case .subtitles(let fields):
            return try await subtitles(fields, client: client)
        }
    }

    // MARK: Commands

    private func capabilities(_ fields: CapabilitiesCommand) async throws(AgentError) -> AgentCapabilities {
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
            let taken = try await agentSpendToday(for: kind)
            let cap = environment.spendCap(for: kind)
            var capTaken: Int?
            if let cap, let committed = try? await environment.committedToday(in: cap.unit) {
                capTaken = AgentCap.money(committed, cap.unit)?.amount
            }
            budget = AgentCapabilities.Budget(
                for: kind, dailyLimit: preferences.dailyBudget(for: kind), taken: taken,
                allowsUnlimited: preferences.allowsUnlimited,
                dailyCap: cap.flatMap { AgentCap.money($0.amount, $0.unit)?.amount }, capTakenToday: capTaken)
        }
        var answer = AgentCapabilities(appVersion: Self.appVersion, connection: connection, budget: budget)
        answer.onDevice = onDeviceAgent.capabilities()
        await environment.subtitles.loadAvailability()
        answer.onDevice?.subtitles = subtitleAgent.capabilities()
        if fields.models {
            answer.models = try models(fields.model, connection: state.kind)
        }
        if fields.imageModels { answer.imageModels = imageModels() }
        if fields.styles {
            answer.styles = (PresetCatalog.cachedPresets(in: environment.layout.presetCacheFolder) ?? [])
                .map { AgentCapabilities.Style(id: $0.id, name: $0.name) }
        }
        if fields.voices {
            answer.voices =
                await environment.voices()?.map { AgentCapabilities.Voice(id: $0.choice.id, name: $0.choice.name) }
                ?? []
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
        let constraints = environment.navigation.modelConstraints
        let capabilities = environment.lastCapabilities
        let optedIn = AppSettings.usesUnlimited(in: environment.defaults)
        return models.map { model in
            AgentCapabilities.Model(
                id: model.rawValue, title: model.title, modes: model.modes.map(AgentVideoOrder.name(of:)),
                resolutions: model.resolutions.map(\.rawValue),
                available: connection != nil && offered.contains(model),
                details: id == nil
                    ? nil
                    : Self.details(
                        of: model, constraints: constraints, capabilities: connection == nil ? nil : capabilities,
                        unlimitedOptIn: optedIn))
        }
    }

    /// A model's limits in each of its modes, as a job on it takes them.
    private static func details(
        of model: VideoModel, constraints: ModelConstraintTable, capabilities: Capabilities?, unlimitedOptIn: Bool
    ) -> AgentCapabilities.ModelDetails {
        let modes = model.modes.map { mode in
            let hasSource = !model.makesClipsWithoutSource || mode != .motionTransfer
            let limits = model.limits(for: mode, hasSource: hasSource, constraints: constraints)
            let variants = AgentVideoOrder.variants(
                of: model, in: mode, capabilities: capabilities, unlimitedOptIn: unlimitedOptIn)
            return AgentCapabilities.ModeDetails(
                mode: AgentVideoOrder.name(of: mode), minSeconds: limits.duration.lowerBound,
                maxSeconds: limits.duration.upperBound, minImages: limits.referenceImages.lowerBound,
                maxImages: limits.referenceImages.upperBound, needsStyle: limits.requiresPreset,
                needsSource: hasSource, maxVariants: variants.maximum, variantsUnavailable: variants.reason)
        }
        return AgentCapabilities.ModelDetails(
            modes: modes, hasDraft: model.offersDraft, makesClipsWithoutSource: model.makesClipsWithoutSource,
            needsPrompt: model.descriptor.requiresPrompt)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
