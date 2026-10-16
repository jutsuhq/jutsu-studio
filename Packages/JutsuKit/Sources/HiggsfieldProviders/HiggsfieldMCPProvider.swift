import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import JutsuCore

#if canImport(os)
    import os

    private let statusLogger = Logger(subsystem: "com.jutsustudio", category: "AccountStatus")
    private let quoteLogger = Logger(subsystem: "com.jutsustudio", category: "AccountQuote")
#endif

/// The account connection: Genjutsu and the models in `AccountModel` through the tools of Higgsfield's MCP
/// server, paid with plan credits. Which modes and operations exist is decided by `tools/list`.
public actor HiggsfieldMCPProvider: GenerationProvider, GenerationHistory {
    public nonisolated let kind = ProviderKind.account
    public nonisolated let owner: String?

    static let notAvailable = ProviderError.validation(
        field: nil, message: String(localized: "Not available for this account", bundle: .module))
    static let notCancellable = ProviderError.validation(
        field: nil,
        message: String(localized: "Higgsfield can't cancel a job from the account connection", bundle: .module))

    let account: HiggsfieldAccount
    private let unlimitedOptIn: @Sendable () async -> Bool
    private let constraints: @Sendable () async -> ModelConstraintTable
    /// The last `models_explore` read; none until `capabilities()`, or when it failed.
    private var allowance = UnlimitedAllowance.none
    /// Set once a `jobs_wait` answer named none of the jobs it was asked about: its shape isn't the one
    /// `JobsWait` reads, so this connection polls each job with `job_status` from then on.
    private var jobsWaitUnreadable = false
    /// `list_voices`, read once for this connection (`voices()`).
    var cachedVoices: [AccountVoice]?
    /// Before-upload quotes, shared for the connection; failed quotes are dropped for a later retry.
    private let quotes = QuoteCache<QuoteKey, Double>()
    public static var offersPostOperations: Bool { true }

    /// - Parameters:
    ///   - owner: `OAuthTokens.owner` of the signed-in account.
    ///   - unlimitedOptIn: whether the user chose to pay from the plan's unlimited allowance where it applies.
    ///   - constraints: the model constraints the app cached from `modelConstraints()`, which the length of a
    ///     request and the estimate keep to, as Create does.
    public init(
        account: HiggsfieldAccount, owner: String?, unlimitedOptIn: @escaping @Sendable () async -> Bool = { false },
        constraints: @escaping @Sendable () async -> ModelConstraintTable = { .builtIn }
    ) {
        self.account = account
        self.owner = owner
        self.unlimitedOptIn = unlimitedOptIn
        self.constraints = constraints
    }

    /// Re-reads `tools/list`; without every tool a job needs, no mode is offered. Restyle runs as a Genjutsu Style.
    /// Edit and Extend, and each model parameter, run behind their switches (`AccountModel.generateModes`,
    /// `AccountModel.parameters`). Also reads the unlimited allowance.
    public func capabilities() async throws -> Capabilities {
        let canGenerate = try await mapped { try await account.refreshTools() }
        var modes = canGenerate ? AccountModel.generateModes : []
        if await account.canRunStyles { modes.insert(.restyle) }
        allowance = canGenerate ? await readAllowance() : .none
        return Capabilities(
            modes: modes,
            models: canGenerate ? Set(VideoModel.allCases.filter(AccountModel.runs)) : [.genjutsu],
            resolutions: Set(Resolution.allCases), costUnit: .credits, maxConcurrency: nil,
            parameters: canGenerate ? AccountModel.parameters : [],
            unlimited: AccountModel.unlimited(allowance, modes: AccountModel.generateModes),
            maxVariants: canGenerate ? JobSpec.maximumVariants : 1)
    }

    /// `models_explore`'s word on the allowance; none when the account has no such tool or the call fails, so a
    /// failure never sends `use_unlim: true`.
    private func readAllowance() async -> UnlimitedAllowance {
        do {
            return try await account.unlimitedAllowance(for: Set(AccountModel.accountModels)) ?? .none
        } catch {
            return .none
        }
    }

    /// Opted in, and the last read of the allowance covers the spec's `generate_video` model. A Genjutsu Style
    /// runs through `execute_preset`, which has no such option, and a finalize always sends `use_unlim: false`.
    public func paysUnlimited(_ spec: JobSpec) async -> Bool {
        guard spec.operation == nil, spec.mode != .restyle, spec.draftJobID == nil, await unlimitedOptIn(),
            let model = AccountModel.model(for: spec)
        else {
            return false
        }
        return allowance.covers(model)
    }

    /// The server's tool and model catalogs as JSON, for Debug › Export MCP Tool Catalog. `owner` and every
    /// string in `redacting` are blanked out of it.
    public func exportCatalog(redacting: [String] = []) async throws -> Data {
        try await mapped { try await account.exportCatalog(redacting: redacting + [owner].compactMap(\.self)) }
    }

    /// A generation of several variants is quoted for one variant, then priced that many times: the variants share
    /// every setting, and `get_cost` leaves `count` out of the price (live, 2026-10-15: `count` 2 quoted the same as
    /// 1), so the quote is one variant's.
    public func serverEstimate(_ spec: JobSpec, inputs: RemoteInputs) async throws -> Cost? {
        try Self.checkVariants(spec)
        let credits: Double?
        if spec.operation != nil {
            let operation = try operationEdit(spec, inputs: inputs).operation
            credits = try await mapped {
                try await account.cost(of: operation, duration: AccountModel.sourceLength(of: spec))
            }
        } else if spec.mode == .restyle {
            let run = try Self.styleRun(spec, inputs: inputs)
            credits = try await mapped { try await account.cost(of: run) }
        } else {
            var request = try await videoRequest(spec, inputs: inputs)
            request.count = 1
            credits = try await mapped { try await account.cost(of: request) }
        }
        // Up: a price must never look lower than what the server charges.
        return try credits.map { try Cost.serverCredits($0, count: spec.variants) }
    }

    public func upload(_ file: PreparedFile) async throws -> RemoteAsset {
        let media = try await mapped { try await account.upload(fileAt: file.fileURL, contentType: file.contentType) }
        return RemoteAsset(url: media.url, id: media.id)
    }

    /// A linked file of at most 50 MB is imported by its link with `media_import_url` (`url`, `type`; a confirmed
    /// `media_id` back, as the catalog snapshot of 2026-10-15 states), so it isn't uploaded. A larger file, a
    /// refused import (the host may block the server's fetch) or an account without the tool uploads it as usual.
    public func linkedAsset(_ origin: URL, kind: MediaLink.Kind, byteCount: Int64) async throws -> RemoteAsset? {
        guard origin.isHTTPS, byteCount > 0, byteCount <= HiggsfieldAccount.importLimit else { return nil }
        return try await mapped {
            do {
                let id = try await account.importMedia(from: origin, type: kind.rawValue)
                return RemoteAsset(url: origin, id: id)
            } catch HiggsfieldError.validation, HiggsfieldError.toolUnavailable {
                return nil
            }
        }
    }

    /// `generate_video` takes no idempotency key, so sending it again could pay twice: any failure once the call
    /// may have reached the server throws `ProviderError.outcomeUnknown`, never an error the engine retries. That
    /// includes cancellation during the call, which can't tell whether the request went out. A task cancelled
    /// before the call throws `CancellationError` and sends nothing. Every further job the answer names, one per
    /// variant, comes back in `RemoteJob.variants`.
    public func submit(_ spec: JobSpec, inputs: RemoteInputs, idempotencyKey: UUID) async throws -> RemoteJob {
        try Self.checkVariants(spec)
        let send: () async throws -> Generation
        var usesUnlimited = false
        var isNativeDraft = false
        if spec.operation != nil {
            let edit = try operationEdit(spec, inputs: inputs)
            send = { try await self.account.run(edit) }
        } else if spec.mode == .restyle {
            let run = try Self.styleRun(spec, inputs: inputs)
            send = { try await self.account.run(run) }
        } else {
            let request = try await videoRequest(spec, inputs: inputs)
            usesUnlimited = request.usesUnlimited
            isNativeDraft = request.draft
            send = { try await self.account.generate(request) }
        }
        try Task.checkCancellation()
        let generation: Generation
        do {
            generation = try await send()
        } catch let error as HiggsfieldError {
            throw Self.mayHaveReachedServer(error) ? ProviderError.outcomeUnknown : ProviderError(error)
        } catch is CancellationError {
            throw ProviderError.outcomeUnknown
        }
        var remote = RemoteJob(requestID: generation.id, correlationID: generation.requestID)
        if usesUnlimited { (remote.paidWithUnlimited, remote.charged) = Self.unlimitedCharge(generation.credits) }
        remote.isNativeDraft = isNativeDraft
        remote.variants = generation.variantIDs.map {
            var variant = RemoteJob(requestID: $0, correlationID: generation.requestID)
            variant.isNativeDraft = isNativeDraft
            return variant
        }
        return remote
    }

    /// A job sent with `use_unlim` is taken as paid from the allowance unless the answer names a price above 0.
    /// The tool's description says a refused opt-in is reported, never charged in credits instead, and its
    /// `outputSchema` sends `cost` only for `get_cost`; the price is still read in case a live answer differs.
    static func unlimitedCharge(_ credits: Double?) -> (paidWithUnlimited: Bool, charged: Cost?) {
        guard let credits, credits != 0 else { return (true, nil) }
        // The job is already accepted: retain its ID and prior quote if the charged amount is unreadable.
        return (false, try? Cost.serverCredits(credits))
    }

    /// Never: `generate_video` has no idempotency key. Fails like `submit` when the tool is missing.
    public func submitIsIdempotent(_ spec: JobSpec) async throws -> Bool {
        if spec.operation != nil {
            let operation = try editOperation(spec)
            try await mapped { try await account.checkTool(for: operation) }
            return false
        }
        try await mapped { try await account.checkGenerate() }
        return false
    }

    /// Lost connections, 5xx and unreadable 2xx replies; 4xx answers mean the call was refused.
    static func mayHaveReachedServer(_ error: HiggsfieldError) -> Bool {
        switch error {
        case .network: true
        case .server(let status): !(400..<500).contains(status)
        default: false
        }
    }

    public func status(_ job: RemoteJob) async throws -> RemoteStatus {
        RemoteStatus(try await mapped { try await account.status(of: job.requestID) })
    }

    public nonisolated let statusBatchLimit = HiggsfieldAccount.jobsWaitLimit

    /// One `jobs_wait` long-poll of `jobs`. `nil`, so the engine asks `job_status` for each job, when the account
    /// has no usable `jobs_wait`, the call fails, or the answer can't be read: the shape is unconfirmed (issue #37),
    /// so a wrong guess costs one extra call, never a stalled job. After an unreadable answer it isn't asked again.
    public func statuses(of jobs: [RemoteJob]) async throws -> BatchStatus? {
        guard !jobsWaitUnreadable, !jobs.isEmpty else { return nil }
        let answer: JobsWait?
        do {
            answer = try await account.waitForJobs(jobs.map(\.requestID))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            #if canImport(os)
                statusLogger.error(
                    "jobs_wait failed, polling each job: \(String(describing: error), privacy: .private)")
            #endif
            return nil
        }
        guard let answer else { return nil }
        guard !answer.statuses.isEmpty else {
            jobsWaitUnreadable = true
            #if canImport(os)
                statusLogger.error("jobs_wait answered in an unknown shape; polling each job from now on")
            #endif
            return nil
        }
        return BatchStatus(statuses: answer.statuses.mapValues(RemoteStatus.init), pollAfter: answer.pollAfterSeconds)
    }

    /// No tool cancels a generation.
    public func cancel(_ job: RemoteJob) async throws {
        throw Self.notCancellable
    }

    /// `nil` when the account exposes no balance tool, as the protocol defines for "can't report".
    /// While the account has an unlimited allowance, reads it again too: this runs after each job, and jobs spend it.
    public func balance() async throws -> Balance? {
        if allowance.isAvailable { allowance = await readAllowance() }
        guard let balance = try await mapped({ try await account.balance() }) else { return nil }
        // Down: credits left must never look higher than they are, or a job the server refuses looks affordable.
        guard let credits = Int(exactly: balance.credits.rounded(.down)) else {
            throw ProviderError.server(status: 200)
        }
        return .credits(credits, plan: balance.plan)
    }

    /// Finished videos and images, of the selected workspace; other media types and models are left out. Each
    /// stream pages on its own, packed into one cursor, so images don't hold back videos or the other way round.
    public func history(after cursor: HistoryCursor?) async throws -> HistoryPage {
        let (videoCursor, imageCursor) = HistoryMapping.splitCursor(cursor)
        // Past its last page a stream isn't asked again; the first page asks both, videos first.
        let videoPage =
            cursor == nil || videoCursor != nil
            ? try await mapped {
                try await account.generations(
                    type: .video, onlyCompleted: true, cursor: videoCursor, size: Self.historyPageSize)
            } : nil
        let imagePage =
            cursor == nil || imageCursor != nil
            ? try await mapped {
                try await account.generations(
                    type: .image, onlyCompleted: true, cursor: imageCursor, size: Self.historyPageSize)
            } : nil
        let videos = videoPage.map(HistoryMapping.page)
        let images = imagePage.map(HistoryMapping.page)
        return HistoryPage(
            items: videos?.items ?? [],
            images: images?.images ?? [],
            nextCursor: HistoryMapping.joinedCursor(video: videos?.nextCursor, image: images?.nextCursor))
    }

    static let historyPageSize = 24

    /// `use_unlim` only for a job queued to be paid that way that still is: opted in, and covered by the allowance.
    private func videoRequest(_ spec: JobSpec, inputs: RemoteInputs) async throws -> VideoRequest {
        guard let model = AccountModel.model(for: spec) else { throw Self.notAvailable }
        let assets = (inputs.video.map { [($0, MediaRole.video)] } ?? []) + inputs.images.map { ($0, .image) }
        let media = try assets.map { asset, role in VideoRequest.Media(role: role, id: try Self.mediaID(asset)) }
        var request = AccountModel.request(for: spec, model: model, media: media, constraints: await constraints())
        // A finalize sends exactly its four keys: `use_unlim: false` and no `count`.
        guard request.draftJobID == nil else { return request }
        request.usesUnlimited = spec.usesUnlimited ? await paysUnlimited(spec) : false
        request.count = spec.variants
        return request
    }

    private func editOperation(_ spec: JobSpec) throws -> VideoEdit.Operation {
        guard let operation = AccountModel.editOperation(for: spec) else { throw Self.notAvailable }
        return operation
    }

    private func operationEdit(_ spec: JobSpec, inputs: RemoteInputs) throws -> VideoEdit {
        let operation = try editOperation(spec)
        guard let input = AccountModel.editInput(for: spec, inputs: inputs) else { throw Self.notAvailable }
        return VideoEdit(operation: operation, input: input)
    }

    static func styleRun(_ spec: JobSpec, inputs: RemoteInputs) throws -> StyleRun {
        guard spec.model == .genjutsu, let presetID = spec.presetID, let video = inputs.video else {
            throw notAvailable
        }
        return StyleRun(
            styleID: GenjutsuMapping.styleID(presetID), videoID: try mediaID(video),
            imageIDs: try inputs.images.map(mediaID), prompt: spec.prompt, resolution: spec.resolution.rawValue)
    }

    /// Assets uploaded before media IDs were kept can't be referenced; the cache expires them.
    private static func mediaID(_ asset: RemoteAsset) throws -> String {
        guard let id = asset.id else {
            throw ProviderError.validation(
                field: nil, message: String(localized: "Unexpected result from the media_upload tool", bundle: .module))
        }
        return id
    }
}

extension HiggsfieldMCPProvider {
    /// The Genjutsu Styles, every page. A broken cursor chain fails instead of returning a partial catalog.
    public func presets() async throws -> [StylePreset] {
        var presets: [StylePreset] = []
        var cursor: JSONValue?
        var seenCursors: Set<JSONValue> = []
        var pages = 0
        repeat {
            let page = try await mapped {
                try await account.genjutsuPresets(.styles, cursor: cursor, limit: Self.stylePageSize)
            }
            presets += page.items.compactMap(GenjutsuMapping.style)
            pages += 1
            // An empty page that still names a next one would never end.
            cursor = page.items.isEmpty ? nil : page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted || pages >= Self.maxStylePages {
                throw ProviderError.server(status: 200)
            }
        } while cursor != nil
        return presets
    }

    static let stylePageSize = 50
    static let maxStylePages = 50

    /// Variants are `generate_video`'s `count`: a Genjutsu Style (`execute_preset`) and an operation on a result
    /// make one. Refused before anything is sent.
    static func checkVariants(_ spec: JobSpec) throws {
        guard spec.variants != 1 else { return }
        guard (1...JobSpec.maximumVariants).contains(spec.variants), spec.operation == nil, spec.mode != .restyle
        else {
            throw ProviderError.validation(
                field: "count", message: String(localized: "Variants aren't available for this job.", bundle: .module))
        }
    }
}

extension HiggsfieldMCPProvider: ModelConstraintsSource {
    /// `models_explore` `get` of each `generate_video` model; `nil` without `models_explore`.
    public func modelConstraints() async throws -> ModelConstraintTable? {
        try await mapped { try await account.modelLimits(of: AccountModel.accountModels) }
            .map(AccountModel.constraints)
    }
}

extension HiggsfieldMCPProvider: MotionLibrary {
    public func motionPresets(on shelf: MotionShelf, after cursor: HistoryCursor?) async throws -> MotionPresetPage {
        guard let category = GenjutsuMapping.category(shelf) else {
            let page = try await uploads(.video, after: cursor)
            return MotionPresetPage(items: page.items.map(AccountMapping.clip), nextCursor: page.nextCursor)
        }
        let page = try await mapped {
            try await account.genjutsuPresets(
                category, cursor: cursor.flatMap(HistoryMapping.cursorValue), limit: Self.motionPageSize)
        }
        // An empty page that still names a next one would never end.
        let next = page.items.isEmpty ? nil : page.nextCursor.flatMap(HistoryMapping.cursor)
        return MotionPresetPage(items: page.items.compactMap(GenjutsuMapping.motion), nextCursor: next)
    }

    static let motionPageSize = 24
}

extension HiggsfieldMCPProvider: GenerationLikes, CreditHistory, AccountUploads {
    public func setLiked(_ requestID: String, _ isLiked: Bool) async throws {
        try await mapped { try await account.setLiked(requestID, liked: isLiked) }
    }

    public func creditHistory(after cursor: HistoryCursor?) async throws -> CreditPage {
        let page = try await mapped {
            try await account.transactions(
                cursor: cursor.flatMap(HistoryMapping.cursorValue), size: Self.creditPageSize)
        }
        // An empty page that still names a next one would never end.
        let next = page.items.isEmpty ? nil : page.nextCursor.flatMap(HistoryMapping.cursor)
        return CreditPage(items: page.items.map(AccountMapping.entry), nextCursor: next)
    }

    public func uploads(_ kind: UploadKind, after cursor: HistoryCursor?) async throws -> UploadPage {
        let page = try await mapped {
            try await account.uploads(
                AccountMapping.assetKind(kind), cursor: cursor.flatMap(HistoryMapping.cursorValue),
                size: Self.uploadPageSize)
        }
        let next = page.items.isEmpty ? nil : page.nextCursor.flatMap(HistoryMapping.cursor)
        return UploadPage(items: page.items.map(AccountMapping.file), nextCursor: next)
    }

    static let creditPageSize = 50
    static let uploadPageSize = 30
}

extension HiggsfieldMCPProvider {
    /// The quote of an operation before anything is uploaded: every operation is priced by the result's length (an
    /// upscale also by its resolution and frame rate), so the result needn't be named. `Cost.unknownCredits` when
    /// Higgsfield gives no quote (Topaz).
    /// Throws `notAvailable` when the tool can't take the spec or the account has no such tool.
    func operationEstimate(_ spec: JobSpec) async throws -> Cost {
        let operation = try editOperation(spec)
        try await mapped { try await account.checkTool(for: operation) }
        let length = AccountModel.sourceLength(of: spec)
        guard let credits = try await mapped({ try await account.cost(of: operation, duration: length) }) else {
            return .unknownCredits
        }
        return try .serverCredits(credits, isEstimate: true)
    }
}

extension HiggsfieldMCPProvider {
    /// The price before anything is uploaded. A model sent a length is quoted by `get_cost` without media
    /// (`AccountModel.quoteRequest`), which is the exact price; a model billed by its source (Genjutsu, Edit) and a
    /// Genjutsu Style can be quoted only with the uploaded source, so they get the catalog's estimate, as does a
    /// quote that fails (`AccountModel.estimatedCredits`, `styleCredits`); `Cost.unknownCredits` when there is no
    /// rate either. A generation of several variants costs one variant's price that many times.
    public func estimate(_ spec: JobSpec) async throws -> Cost {
        try Self.checkVariants(spec)
        if spec.operation != nil { return try await operationEstimate(spec) }
        if spec.mode == .restyle { return .credits(Decimal(AccountModel.styleCredits(for: spec)), isEstimate: true) }
        guard let model = AccountModel.model(for: spec) else { throw Self.notAvailable }
        let constraints = await constraints()
        if let request = AccountModel.quoteRequest(for: spec, model: model, constraints: constraints),
            let credits = try await quote(request),
            // A malformed price falls back to the estimate.
            let quoted = try? Cost.serverCredits(credits, count: spec.variants)
        {
            return quoted
        }
        guard let credits = AccountModel.estimatedCredits(for: spec, constraints: constraints) else {
            return .unknownCredits
        }
        return Cost.credits(Decimal(credits), isEstimate: true).times(spec.variants)
    }

    /// What a quote before upload is priced on: the model, its `mode`, the resolution, the length, the
    /// soundtrack and, for a finalize, its draft. Requests that differ only in the rest (the frame, the bitrate,
    /// `draft`, which priced the same live) share a quote.
    struct QuoteKey: Hashable {
        var model: String
        var mode: String?
        var resolution: String?
        var duration: Double?
        // swiftlint:disable:next discouraged_optional_boolean
        var generateAudio: Bool?
        var draftJobID: String?

        init(_ request: VideoRequest) {
            model = request.model.rawValue
            mode = request.mode
            resolution = request.resolution
            duration = request.duration
            generateAudio = request.generateAudio
            draftJobID = request.draftJobID
        }
    }

    /// The `get_cost` quote of `request` in credits, asked once per `QuoteKey`: a second estimate of the same job,
    /// even while the first is out, reads the same answer. Free, and submits nothing. `nil` when the quote fails,
    /// which isn't kept, so a later estimate asks again.
    func quote(_ request: VideoRequest) async throws -> Double? {
        let account = account
        do {
            return try await quotes.value(for: QuoteKey(request)) { try await account.cost(of: request) }
        } catch {
            try Task.checkCancellation()
            #if canImport(os)
                quoteLogger.error(
                    "get_cost failed, showing the estimate: \(String(describing: error), privacy: .private)")
            #endif
            return nil
        }
    }
}
