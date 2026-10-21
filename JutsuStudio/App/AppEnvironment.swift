import AppKit
import Foundation
import HiggsfieldMCP
import JobEngine
import JutsuCore
import MediaKit
import Persistence
import Presentation
import Secrets
import SwiftData
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "App")

/// The composition root: built once at launch, holds every long-lived object and wires the provider
/// of the active connection into the engine. Views get it with `@Environment(AppEnvironment.self)`.
@MainActor
@Observable
final class AppEnvironment {
    let layout: FileLayout
    let modelContainer: ModelContainer
    let engine: JobEngine
    let connection: ConnectionStore
    /// Every job as of the engine's last event; the Queue, sidebar badge and menu bar read it.
    let liveJobs: LiveJobs
    let navigation: NavigationModel
    let outputFolder: OutputFolder
    /// The active account's model constraints, which Create's limits and the account's requests read.
    let modelConstraints: ModelConstraintStore
    /// Prices of reference image requests and virality scores, which the daily cap and Spending count beside the jobs.
    let imageSpend: ImageSpendLog
    /// Create's Generate… sheet: its form, runs and this session's images.
    let referenceGenerator: ReferenceGenerator
    /// Library › Images: the images Generate… made, saved in the output folder.
    let imageLibrary: ImageLibrary
    /// Create Character: its form and runs, and every character sheet job the app started.
    let characterBuilder: CharacterBuilder
    /// Score Variants in batch comparison: its runs, which outlive the comparison, and why a score is missing.
    let variantScorer: VariantScorer
    /// What agents' jobs took from the daily agent budget, apart from the job store (`AgentSpendPolicy`).
    let agentSpend: AgentSpendFile
    /// The `create_video`, `create_image` and `enhance` requests agents sent, so the same one sent again returns its
    /// job.
    let agentRequests: AgentRequestLog
    /// Agents' `create_image` requests, sent through Generate…'s runs behind the agents' spending guard.
    let agentImages: AgentImageQueue
    /// The models the connection runs video jobs on, from the last capabilities read on Create; Genjutsu alone
    /// until they are known. The menu bar's New from Template applies against these.
    var lastOfferedModels: Set<VideoModel> = [.genjutsu]
    /// The connection's capabilities as `capabilities()` last read them; `nil` until then and after the provider
    /// changes, so another account's never answer. Agents' `capabilities` answers from it rather than calling the
    /// provider.
    private(set) var lastCapabilities: Capabilities?
    /// The provider of the active connection; `nil` while disconnected.
    private(set) var provider: (any GenerationProvider)? = nil
    /// Goes up whenever `provider` is replaced, a new sign-in to the same account included. Provider-backed
    /// loads key on it rather than on `connection.state`, which also changes with every balance refresh.
    private(set) var providerGeneration = 0
    /// The account's history as Library pages through it; emptied when the connection changes.
    var history = AccountHistory()
    /// Remote IDs of history items whose result is being downloaded into the library.
    var importingHistory: Set<String> = []
    /// Pause All or Resume All is running (`runOnAllJobs`); every place that offers them waits for it.
    var isChangingAllJobs = false
    /// The last settings write sent to the engine (`writeSetting`); the next one waits for it.
    @ObservationIgnored var settingsWrite: Task<Void, Never>?

    @ObservationIgnored let store: SwiftDataStore
    /// Read by the app-side extensions (spend cap); never `.standard` directly, so tests and previews can inject.
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored var materialAccess: [SecurityScopedAccess] = []

    init(layout: FileLayout = FileLayout(), defaults: UserDefaults = .standard) throws {
        AppSettings.migrate(defaults)
        let container = try StoreContainer.make(inMemory: false, layout: layout)
        let store = SwiftDataStore(modelContainer: container)
        let outputFolder = OutputFolder(layout: layout, defaults: defaults)
        let settings = EngineSettings(
            outputDirectory: outputFolder.url(of: .videos),
            outputNamePattern: AppSettings.outputNamePattern(in: defaults),
            maxConcurrency: AppSettings.maxConcurrency(in: defaults, for: nil))
        let metadata = UserDefaultsMetadataStore(defaults: defaults)
        self.layout = layout
        self.outputFolder = outputFolder
        self.store = store
        self.defaults = defaults
        liveJobs = LiveJobs()
        navigation = NavigationModel(draftStore: CreateDraftStore(fileURL: layout.createDraftURL), defaults: defaults)
        modelContainer = container
        modelConstraints = ModelConstraintStore(cache: ModelConstraintCache(folder: layout.cacheFolder))
        let imageSpend = ImageSpendLog(folder: layout.root)
        self.imageSpend = imageSpend
        let spending = SpendReader(defaults: defaults, store: store, images: imageSpend)
        let referenceGenerator = ReferenceGenerator(
            spend: imageSpend, jobLog: ImageJobLog(folder: layout.root), spendStatus: spending.status(for:))
        self.referenceGenerator = referenceGenerator
        let imageLibrary = ImageLibrary(layout: layout, outputFolder: outputFolder, catalog: store)
        self.imageLibrary = imageLibrary
        Self.saveGeneratedImages(of: referenceGenerator, into: imageLibrary)
        // The Image side of the Create draft, kept across launches; the models arrive later and settle the choice.
        referenceGenerator.restore(navigation.imageDraft)
        let characterBuilder = CharacterBuilder(
            log: CharacterSheetLog(folder: layout.root), spend: imageSpend, spendStatus: spending.status(for:))
        self.characterBuilder = characterBuilder
        Self.saveCharacterSheets(of: characterBuilder, into: imageLibrary)
        variantScorer = VariantScorer(spend: imageSpend, spendStatus: spending.status(for:))
        let agentSpend = AgentSpendFile(file: layout.root.appending(path: "agent-spend.json"))
        self.agentSpend = agentSpend
        agentRequests = AgentRequestLog(folder: layout.root)
        agentImages = Self.agentImageQueue(
            folder: layout.root, generator: referenceGenerator, ledger: agentSpend, defaults: defaults)
        engine = JobEngine(
            provider: nil, repository: store, uploadCache: store,
            media: MediaPreparer(workingDirectory: layout.sourcesFolder), connectivity: PathConnectivity(),
            settings: settings, presetName: { PresetCatalog.cachedName(of: $0, in: layout.presetCacheFolder) },
            spendStatus: { job in try await spending.status(excluding: job) },
            agentPolicy: Self.agentPolicy(ledger: agentSpend, defaults: defaults))
        connection = ConnectionStore(
            vault: Self.connectionVault(), metadata: metadata, services: HiggsfieldConnectionServices())
        connection.onCredentialChange = { [weak self] credential in await self?.use(credential) }
        modelConstraints.onChange = { [weak self] table in self?.useModelConstraints(table) }
    }

    /// The agents' image requests, held to the person's daily agent budget.
    private static func agentImageQueue(
        folder: URL, generator: ReferenceGenerator, ledger: AgentSpendFile, defaults: UserDefaults
    ) -> AgentImageQueue {
        AgentImageQueue(
            folder: folder, generator: generator, ledger: ledger,
            dailyLimit: { AgentPreferences(defaults: defaults).dailyBudget(for: $0) })
    }

    /// Hands the restored connection to the engine, then resumes the jobs of the last session. Runs once, and never
    /// in a smoke test: the window's own start would resume real jobs and send prepared submits.
    func start() async {
        guard !isStarted, !SmokeTest.isRequested else { return }
        isStarted = true
        // Consume before anything can make the engine emit; the stored copies never replace an event.
        let events = engine.events
        eventsTask = Task { [weak self, liveJobs] in
            await liveJobs.consume(events) { _ in self?.scheduleBalanceRefresh() }
        }
        liveJobs.seed(storedJobs())
        Task { [store, liveJobs] in
            await liveJobs.addHistory(Self.generationHistory(store))
        }
        pruneTemplateImages()
        pruneOutputFolders()
        await reopenCatalogFiles()
        Task {
            await imageLibrary.load()
            await imageLibrary.resumePendingSaves()
        }
        // Before the connection, whose image requests and character sheets are followed again: a poll turned down
        // for the sign-in asks for it again, as a job's does.
        referenceGenerator.onSignInExpired = { [weak self] in self?.connection.markNeedsAttention() }
        characterBuilder.onSignInExpired = { [weak self] in self?.connection.markNeedsAttention() }
        // Before the connection resumes them: orphaned reservations go back and held requests show again.
        await agentImages.restore()
        await engine.onConnectionNeedsAttention { [weak self] in
            await MainActor.run { self?.connection.markNeedsAttention() }
        }
        await connection.activate()
        await startEngine()
    }

    /// Unfinished jobs may already be paid for, so a store that can't be read right now is tried again
    /// rather than leaving them unpolled until the next launch.
    private func startEngine() async {
        let retryDelays: [Duration] = [.seconds(2), .seconds(10), .seconds(60)]
        for attempt in 0...retryDelays.count {
            do {
                try await engine.start()
                return
            } catch {
                logger.error(
                    "Can't resume jobs (attempt \(attempt + 1, privacy: .public)): \(String(describing: error), privacy: .private)"
                )
            }
            guard attempt < retryDelays.count else { break }
            do { try await Task.sleep(for: retryDelays[attempt]) } catch { return }
        }
        logger.fault("Gave up resuming jobs; unfinished jobs won't be polled until the next launch")
    }

    /// What the active connection can run, for mode pickers. Flags the connection on 401. Also reads the model
    /// constraints again when they are a day old.
    func capabilities() async -> Capabilities? {
        guard let provider else {
            lastCapabilities = nil
            return nil
        }
        refreshModelConstraints()
        let generation = providerGeneration
        do {
            let capabilities = try await provider.capabilities()
            // Read for a provider replaced meanwhile: not this connection's.
            guard providerGeneration == generation else { return nil }
            lastCapabilities = capabilities
            return capabilities
        } catch {
            if error as? ProviderError == .unauthorized { connection.markNeedsAttention() }
            logger.error("Can't load capabilities: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func use(_ credential: Credential?) async {
        let generation = connection.credentialGeneration
        let provider = credential.map { credential in
            ProviderFactory.provider(
                for: credential,
                persist: { [weak self] refreshed in await self?.saveRefreshed(refreshed, generation: generation) },
                unlimitedOptIn: { [weak self] in await self?.usesUnlimited() ?? false },
                constraints: { [weak self] in await self?.modelConstraints.table ?? .builtIn })
        }
        self.provider = provider
        providerGeneration += 1
        lastCapabilities = nil
        followCharacterSheets()
        followImageJobs()
        history.switchAccount(to: provider.map { "\($0.kind.rawValue)|\($0.owner ?? "")" })
        // Before the provider, so the jobs it lets through take the connection's slots.
        let limit = AppSettings.maxConcurrency(in: defaults, for: provider?.kind)
        await writeSetting { await $0.setMaxConcurrency(limit) }.value
        await engine.setProvider(provider)
        scheduleBalanceRefresh()
        await loadModelConstraints()
    }

    /// The account's Unlimited generations setting, from the defaults this environment was built with.
    private func usesUnlimited() -> Bool {
        AppSettings.usesUnlimited(in: defaults)
    }

    private func saveRefreshed(_ tokens: OAuthTokens, generation: Int) {
        do {
            if !(try connection.saveRefreshedTokens(tokens, generation: generation)) {
                logger.info("Dropped tokens refreshed for a connection that has since changed")
            }
        } catch {
            logger.error("Can't save refreshed sign-in: \(String(describing: error), privacy: .private)")
        }
    }

    /// Off the event loop, so a slow balance call never delays the Queue.
    private func scheduleBalanceRefresh() {
        Task { await refreshBalance() }
    }

    /// Reads the connection's balance again, on connect and whenever a job finishes.
    private func refreshBalance() async {
        guard let provider else { return }
        await connection.refreshBalance(from: provider)
    }

    /// Done jobs for the typical generation time, fetched and decoded on the store's actor.
    private static func generationHistory(_ store: SwiftDataStore) async -> [Job] {
        do {
            return try await store.doneJobs(limit: LiveJobs.generationHistoryLimit)
        } catch {
            logger.error("Can't load generation history: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// Forgets earlier output folders that no job's result, download or saved image is in any more. Skipped when the
    /// store or the image index can't be read, so a folder is never forgotten while its results might still be in the
    /// library. An image on a drive that isn't connected stays in the index, so its folder is kept too.
    private func pruneOutputFolders() {
        let candidates = outputFolder.previousFolders
        guard !candidates.isEmpty else { return }
        Task { [store, outputFolder, imageLibrary] in
            do {
                let jobs = try await store.activeJobs() + store.finishedJobs()
                let files =
                    jobs.flatMap { [$0.outputFile, $0.downloadFolder].compactMap(\.self) }
                    + (try await imageLibrary.storedFiles())
                outputFolder.forgetPreviousFolders(candidates, keeping: files)
            } catch {
                logger.error("Can't check earlier output folders: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// The work outside the queue that a quit or a closed last window has to account for: Generate… requests and
    /// character sheets being sent or followed, and finished images being saved into Library › Images.
    var imageWork: ImageWork {
        let saving = imageLibrary.pendingSaveCount
        return ImageWork(
            running: referenceGenerator.activeCount + characterBuilder.activeCount + saving,
            waiting: referenceGenerator.sendingCount + (characterBuilder.isSubmitting ? 1 : 0) + saving)
    }

    /// Waits for the image and character sheet submits already sent to be answered, so their job IDs are written
    /// down, and for the finished images being saved.
    func finishImageWork() async {
        await referenceGenerator.finishSubmits()
        await characterBuilder.finishSubmit()
        await imageLibrary.finishSaving()
    }

    /// Active jobs and the most recently finished ones, so the Queue isn't empty before the first event.
    private func storedJobs() -> [Job] {
        var finished = JobRecord.finishedNewestFirst
        finished.fetchLimit = LiveJobs.storedFinishedLimit
        let active = FetchDescriptor<JobRecord>(predicate: #Predicate<JobRecord> { $0.isTerminal == false })
        do {
            let context = modelContainer.mainContext
            return try (context.fetch(active) + context.fetch(finished)).compactMap { try? $0.job() }
        } catch {
            logger.error("Can't load stored jobs: \(String(describing: error), privacy: .private)")
            return []
        }
    }
}

// Launch.
extension AppEnvironment {
    /// The app can't run without its store: on failure the user sees why and where it lives, then it quits.
    static func launch() -> AppEnvironment {
        // Both builds' containers link Movies to the real ~/Movies; a Debug build downloads next to, not into,
        // the release build's results.
        #if DEBUG
            let layout = FileLayout(
                defaultOutputFolder: URL.moviesDirectory.appending(
                    path: "Jutsu Studio Debug", directoryHint: .isDirectory))
        #else
            let layout = FileLayout()
        #endif
        do {
            return try AppEnvironment(layout: layout)
        } catch {
            logger.fault("Can't open the library: \(String(describing: error), privacy: .private)")
            showLibraryFailure(error, dataFolder: layout.root)
            exit(EXIT_FAILURE)
        }
    }

    /// Runs before any window exists, so it is a modal alert. "Show Data Folder" leaves it up.
    private static func showLibraryFailure(_ error: any Error, dataFolder: URL) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Jutsu Studio can't open its library")
        let folder = dataFolder.path(percentEncoded: false)
        alert.informativeText =
            "\(error.localizedDescription)\n\n"
            + String(
                localized: """
                    The library is in \(folder). Free up disk space or move the folder aside, \
                    then open the app again.
                    """)
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Show Data Folder"))
        while alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([dataFolder])
        }
    }

    /// The login keychain isn't per container like the defaults are, so a Debug build keeps its own item.
    private static func connectionVault() -> KeychainVault {
        #if DEBUG
            KeychainVault(store: .developmentConnection)
        #else
            KeychainVault(store: .activeConnection)
        #endif
    }

    /// The engine reads the daily agent budget off the main actor, from the person's current settings.
    private static func agentPolicy(ledger: AgentSpendFile, defaults: UserDefaults) -> AgentSpendPolicy {
        // UserDefaults is safe to read from any thread.
        nonisolated(unsafe) let defaults = defaults
        return AgentSpendPolicy(
            ledger: ledger, dailyLimit: { AgentPreferences(defaults: defaults).dailyBudget(for: $0) },
            allowsUnlimited: { AgentPreferences(defaults: defaults).allowsUnlimited })
    }
}
