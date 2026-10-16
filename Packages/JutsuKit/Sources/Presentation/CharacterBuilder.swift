import Foundation
import JutsuCore
import Observation

/// One Generate of Create Character and where it is.
public struct CharacterRun: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case sending
        case running
        case finished
        case failed(String)
        /// Following it stopped before it ended: the sign-in expired or its status couldn't be read. Its sheets and
        /// price are kept, and it is followed again (`resume`).
        case interrupted(String)
    }

    public let id: UUID
    public var count: Int
    public var state: State

    public init(id: UUID, count: Int, state: State) {
        self.id = id
        self.count = count
        self.state = state
    }
}

/// What Create Character asks for and runs: a person or an animal, its traits or a preset, a description, an optional
/// face and style references, Randomize and the number of sheets; the exact price before Generate; and the sheets it
/// starts. The price is the provider's quote of the exact request, and Generate sends that quoted request, never the
/// form again: a randomized design differs each time it is quoted.
///
/// Money: one click sends one submit, and a submit is never sent again. Its price is written to today's spend before
/// it is sent, and nothing is sent when that write fails; it is taken off when the provider refused it, and kept when
/// the outcome is unknown. Every job ID of the answer goes into `CharacterSheetLog` before anything else happens, and
/// is polled until it ends, after a relaunch too (`resume`).
@MainActor
@Observable
public final class CharacterBuilder {
    // MARK: Form

    public private(set) var tier = CharacterTier.normal
    /// Trait IDs by group ID.
    public private(set) var traits: [String: [String]] = [:]
    public var brief = ""
    /// The seed of the preset the form came from; `nil` without one.
    public private(set) var seed: Int?
    public private(set) var preset: CharacterPreset?
    /// The face the sheets keep.
    public var face: LocalImage?
    public private(set) var styles: [LocalImage] = []
    /// Fill the traits left unset at random.
    public var randomize = true
    /// Sheets to make, 1–4.
    public var count = 1

    public private(set) var traitGroups: [CharacterTraitGroup] = []
    public private(set) var traitsFailure: String?

    // MARK: Price and runs

    /// The last quote; `currentQuote` says whether it is still the form's.
    public private(set) var quote: CharacterQuote?
    private var quotedKey: String?
    private var failure: (key: String, message: String)?
    /// Goes up after each submit, so the next Generate is quoted afresh.
    private var round = 0
    /// A submit is out; Generate waits for its answer.
    public private(set) var isSubmitting = false
    public private(set) var runs: [CharacterRun] = []

    /// Called with each sheet as it finishes, to save it (`CharacterSheetLog.setFile` reports where).
    @ObservationIgnored public var onSheets: (([CharacterSheetRecord]) -> Void)?
    /// Called when Higgsfield turned a poll down because the sign-in no longer works, to ask for it again.
    @ObservationIgnored public var onSignInExpired: (() -> Void)?
    @ObservationIgnored public let log: CharacterSheetLog
    @ObservationIgnored private let spend: ImageSpendLog
    @ObservationIgnored private let spendStatus: SpendStatusReader
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var traitsByTier: [CharacterTier: [CharacterTraitGroup]] = [:]
    @ObservationIgnored private var uploads: [LocalImage: RemoteAsset] = [:]
    /// Goes up with each connection (`reset`), so an upload that outlived the old one isn't kept.
    @ObservationIgnored private var generation = 0
    /// The submit out, if any; quitting waits for its answer (`finishSubmit`).
    @ObservationIgnored private var submitTask: Task<Void, Never>?
    /// The polls, by request.
    @ObservationIgnored private var followers: [UUID: Task<Void, Never>] = [:]

    /// - Parameter spendStatus: today's spend and the cap, read before each submit.
    public init(
        log: CharacterSheetLog, spend: ImageSpendLog, spendStatus: @escaping SpendStatusReader = { _ in nil },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.log = log
        self.spend = spend
        self.spendStatus = spendStatus
        self.sleep = sleep
        self.now = now
    }

    /// The trait groups of the tier, read once per tier and connection.
    public func loadTraits(from maker: any CharacterSheetMaker) async {
        let tier = tier
        if let cached = traitsByTier[tier] {
            traitGroups = cached
            return
        }
        traitsFailure = nil
        do {
            let groups = try await maker.characterTraits(for: tier)
            traitsByTier[tier] = groups
            if self.tier == tier { traitGroups = groups }
        } catch is CancellationError {
            return
        } catch {
            if self.tier == tier { traitsFailure = UserMessage(error)?.message ?? Self.cantLoadTraits }
        }
    }

    /// A new connection: its traits are read again, and its uploads aren't the old one's.
    public func reset() {
        stopFollowing()
        generation += 1
        traitsByTier = [:]
        traitGroups = []
        uploads = [:]
        quote = nil
        quotedKey = nil
        failure = nil
        clearPreset()
    }

    // MARK: Price

    /// Why there is no price or Generate; `nil` when the form can be quoted.
    public var blocker: String? {
        brief.count > CharacterDesign.maxBrief
            ? String(localized: "Keep the description under 4,000 characters.", bundle: .module) : nil
    }

    /// Everything the request is made of, and the round.
    public var quoteKey: String {
        let picked = traits.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.joined(separator: ","))" }
        return [
            tier.rawValue, picked.joined(separator: ";"), brief, seed.map(String.init) ?? "", String(count),
            face?.fileURL.absoluteString ?? "", styles.map(\.fileURL.absoluteString).joined(separator: ","),
            String(randomize), String(round),
        ].joined(separator: "\u{1F}")
    }

    /// The quote of the form as it stands; `nil` while it is being read, or when it can't be.
    public var currentQuote: CharacterQuote? { quotedKey == quoteKey ? quote : nil }

    /// Why the form as it stands has no price.
    public var quoteFailure: String? {
        guard let failure, failure.key == quoteKey else { return nil }
        return failure.message
    }

    public var isQuoting: Bool { blocker == nil && currentQuote == nil && quoteFailure == nil }

    /// Asks the provider for the exact request and price of the form, uploading the face and styles first unless
    /// they already were. Free: nothing is generated.
    public func refreshQuote(
        maker: any CharacterSheetMaker, upload: (LocalImage) async throws -> RemoteAsset
    ) async {
        guard blocker == nil else { return }
        let key = quoteKey
        do {
            let design = try await design(upload: upload)
            let quote = try await maker.quoteCharacters(design)
            try Task.checkCancellation()
            guard key == quoteKey else { return }
            self.quote = quote
            quotedKey = key
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, key == quoteKey else { return }
            failure = (key, UserMessage(error)?.message ?? Self.cantPrice)
        }
    }

    private func design(upload: (LocalImage) async throws -> RemoteAsset) async throws -> CharacterDesign {
        func asset(_ image: LocalImage) async throws -> RemoteAsset {
            if let asset = uploads[image] { return asset }
            let generation = generation
            let asset = try await upload(image)
            // An upload that outlived its connection is the old account's media: never offered to the new one.
            if generation == self.generation { uploads[image] = asset }
            return asset
        }
        var styleAssets: [RemoteAsset] = []
        for style in styles { styleAssets.append(try await asset(style)) }
        var faceAsset: RemoteAsset?
        if let face { faceAsset = try await asset(face) }
        return CharacterDesign(
            tier: tier, traits: traits, brief: brief.trimmingCharacters(in: .whitespacesAndNewlines), seed: seed,
            count: count, face: faceAsset, styles: styleAssets, randomize: randomize)
    }

    // MARK: Generate

    /// Sends the current quote once and follows its sheets. Refused while a submit is out or without a quote of the
    /// form as it stands, and when its price can't be written first (the run says so). Unless `overCapApproved`,
    /// today's spend is read first, and a quote that takes today past the cap sends nothing and asks
    /// (`ReferenceGenerator.capConfirmation`).
    /// - Parameter overCapApproved: the user agreed to go past today's cap with this request.
    @discardableResult
    public func generate(maker: any CharacterSheetMaker, overCapApproved: Bool = false) async -> PaidStart {
        guard !isSubmitting, let quote = currentQuote else { return .notStarted }
        do {
            if let status = try await spendStatus(.account), !overCapApproved,
                let question = ReferenceGenerator.capConfirmation(
                    cost: quote.cost, committedToday: status.committedToday, cap: status.cap)
            {
                return .needsConfirmation(question)
            }
        } catch {
            runs.insert(CharacterRun(id: UUID(), count: quote.count, state: .failed(error.localizedDescription)), at: 0)
            return .notStarted
        }
        // While today's spend was read, another click may have sent it, or the form moved on.
        guard !isSubmitting, currentQuote == quote else { return .notStarted }
        let id = UUID()
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        runs.removeAll { $0.state == .finished }
        do {
            try spend.add(
                ImageCharge(
                    id: id, date: now(), cost: quote.cost, providerKind: .account, model: Self.chargeTitle,
                    images: quote.count, purpose: .characterSheets))
        } catch {
            runs.insert(CharacterRun(id: id, count: quote.count, state: .failed(ImageSpendLog.notSent(error))), at: 0)
            return .notStarted
        }
        isSubmitting = true
        runs.insert(CharacterRun(id: id, count: quote.count, state: .sending), at: 0)
        // Not kept with the polls: a sign-out mustn't cut off a submit that may already be paid for.
        submitTask = Task {
            await submit(quote, id: id, brief: brief, maker: maker)
            submitTask = nil
        }
        return .started
    }

    private func submit(_ quote: CharacterQuote, id: UUID, brief: String, maker: any CharacterSheetMaker) async {
        let jobs: [RemoteJob]
        do {
            jobs = try await maker.generateCharacters(quote)
        } catch {
            isSubmitting = false
            round += 1
            if ReferenceGenerator.wasRefused(error) {
                spend.remove(id)
                finish(id, .failed(UserMessage(error)?.message ?? Self.couldNotMake))
            } else {
                // It may have started and been charged: counted, and never sent again.
                spend.settle(id)
                finish(id, .failed(Self.mayHaveStarted))
            }
            return
        }
        let date = now()
        log.add(
            jobs.map {
                CharacterSheetRecord(id: $0.requestID, owner: maker.owner, requestID: id, createdAt: date, brief: brief)
            })
        round += 1
        isSubmitting = false
        finish(id, .running)
        follow(id, maker: maker)
    }

    private func finish(_ id: UUID, _ state: CharacterRun.State) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].state = state
    }

    static let chargeTitle = String(localized: "Character sheets", bundle: .module)
    static let couldNotMake = String(localized: "Higgsfield couldn't make the character sheet.", bundle: .module)
    static let cantPrice = String(localized: "Can't get the price of this character.", bundle: .module)
    static let cantLoadTraits = String(localized: "Can't load the traits.", bundle: .module)
    public static let mayHaveStarted = String(
        localized: """
            Higgsfield may have started these sheets, so they weren't sent again. Check your history on \
            higgsfield.ai before trying again.
            """, bundle: .module)
}

// MARK: Following

extension CharacterBuilder {
    /// Follows the sheets of `maker`'s account still running, as after a relaunch, a new sign-in or a poll that
    /// couldn't be read.
    public func resume(maker: any CharacterSheetMaker) {
        for request in Set(log.pending(of: maker.owner).map(\.requestID)) where followers[request] == nil {
            finish(request, .running)
            follow(request, maker: maker)
        }
    }

    /// Stops polling; the sheets stay pending in the log and are followed again by `resume`.
    public func stopFollowing() {
        for task in followers.values { task.cancel() }
        followers = [:]
    }

    private func follow(_ request: UUID, maker: any CharacterSheetMaker) {
        followers[request] = Task { [weak self] in
            await self?.poll(request, maker: maker)
        }
    }

    /// Polls until every sheet of the request ended, backing off like the engine (`Backoff.polling`). Errors that
    /// waiting can fix are polled through. Any other stops following and leaves the sheets pending and the price
    /// counted, as Generate…'s runs do: a 401 also asks for the sign-in again (`onSignInExpired`), and `resume`
    /// follows them again after it.
    private func poll(_ request: UUID, maker: any CharacterSheetMaker) async {
        var delay = Backoff.polling()
        var interruption: (any Error)?
        while !Task.isCancelled {
            let pending = log.records.filter { $0.requestID == request && $0.state == .pending }
            if pending.isEmpty { break }
            do {
                if try await pollOnce(pending, maker: maker) { delay.reset() }
            } catch is CancellationError {
                return
            } catch {
                interruption = error
                break
            }
            if log.records.allSatisfy({ $0.requestID != request || $0.state != .pending }) { break }
            do {
                try await sleep(.seconds(delay.next()))
            } catch {
                break
            }
        }
        guard !Task.isCancelled else { return }
        stopPolling(request, interruption: interruption)
    }

    /// One poll of the sheets still pending; returns whether one finished. An error waiting can fix is no news.
    private func pollOnce(_ pending: [CharacterSheetRecord], maker: any CharacterSheetMaker) async throws -> Bool {
        do {
            return apply(
                try await maker.characterSheetStatuses(pending.map { RemoteJob(requestID: $0.id) }), to: pending)
        } catch let error as ProviderError where error.isTransient {
            return false
        }
    }

    private func stopPolling(_ request: UUID, interruption: (any Error)?) {
        followers[request] = nil
        guard let interruption else { return end(request) }
        if interruption as? ProviderError == .unauthorized { onSignInExpired?() }
        finish(request, .interrupted(ReferenceGenerator.interrupted(by: interruption)))
    }

    /// Every sheet of the request ended: charged when one was made, else taken off.
    private func end(_ request: UUID) {
        let records = log.records.filter { $0.requestID == request }
        if records.contains(where: { $0.state == .completed }) {
            spend.settle(request)
            finish(request, .finished)
        } else {
            spend.remove(request)
            finish(request, .failed(Self.failureMessage(records)))
        }
    }

    /// Writes down what the poll answered and hands the finished sheets to `onSheets`; returns whether any finished.
    private func apply(_ statuses: [String: ImageJobStatus], to pending: [CharacterSheetRecord]) -> Bool {
        var finished: [CharacterSheetRecord] = []
        for record in pending {
            switch statuses[record.id] {
            case .completed(let urls)?:
                log.update(record.id, state: .completed, imageURL: urls.first)
                if let done = log.records.first(where: { $0.id == record.id }) { finished.append(done) }
            case .failed(let message)?: log.update(record.id, state: .failed(message))
            case .rejected?: log.update(record.id, state: .rejected)
            case .canceled?: log.update(record.id, state: .failed(nil))
            case .pending?, nil: break
            }
        }
        guard !finished.isEmpty else { return false }
        onSheets?(finished)
        return true
    }

    private static func failureMessage(_ records: [CharacterSheetRecord]) -> String {
        for record in records {
            switch record.state {
            case .rejected:
                return String(localized: "Higgsfield's content check refused the character.", bundle: .module)
            case .failed(let message?): return message
            default: continue
            }
        }
        return couldNotMake
    }
}

// MARK: Work in flight

extension CharacterBuilder {
    /// The sheets of the requests running now, for placeholders.
    public func pendingCount(of owner: String?) -> Int {
        log.pending(of: owner).count
    }

    /// Waits for the submit already sent to be answered, so the jobs it starts are in `log` before a quit.
    public func finishSubmit() async {
        await submitTask?.value
    }

    /// Requests being sent or followed until their sheets arrive.
    public var activeCount: Int { (isSubmitting ? 1 : 0) + followers.count }
}

// MARK: Form

extension CharacterBuilder {
    public var kind: CharacterTier.Kind { tier.kind }

    /// A person or an animal; picking the other kind starts from its first tier.
    public func selectKind(_ kind: CharacterTier.Kind) {
        guard kind != tier.kind, let first = kind.tiers.first else { return }
        selectTier(first)
    }

    /// A new tier drops the traits and the preset, which belong to the old one.
    public func selectTier(_ tier: CharacterTier) {
        guard tier != self.tier else { return }
        self.tier = tier
        traits = [:]
        seed = nil
        preset = nil
        traitGroups = traitsByTier[tier] ?? []
        traitsFailure = nil
    }

    /// Picks `trait`, or unpicks it. Over the group's limit, the earliest pick goes.
    public func toggle(_ trait: CharacterTrait, in group: CharacterTraitGroup) {
        var picked = traits[group.id] ?? []
        if let index = picked.firstIndex(of: trait.id) {
            picked.remove(at: index)
        } else {
            picked.append(trait.id)
            if picked.count > group.maxPicks { picked.removeFirst(picked.count - group.maxPicks) }
        }
        traits[group.id] = picked.isEmpty ? nil : picked
    }

    public func isPicked(_ trait: CharacterTrait, in group: CharacterTraitGroup) -> Bool {
        traits[group.id]?.contains(trait.id) == true
    }

    /// Fills the form with what makes `preset` again, and turns Randomize off so it stays that character.
    public func apply(_ preset: CharacterPreset) {
        guard let settings = preset.settings else { return }
        if settings.tier != tier { selectTier(settings.tier) }
        traits = settings.traits
        brief = settings.brief
        seed = settings.seed
        randomize = false
        self.preset = preset
    }

    /// Keeps the form, without the preset's seed.
    public func clearPreset() {
        preset = nil
        seed = nil
    }

    /// Adds style references up to `CharacterDesign.maxStyles`; returns how many were left out.
    @discardableResult
    public func addStyles(_ images: [LocalImage]) -> Int {
        let room = CharacterDesign.maxStyles - styles.count
        styles += images.prefix(max(room, 0))
        return max(images.count - max(room, 0), 0)
    }

    public func removeStyle(at index: Int) {
        guard styles.indices.contains(index) else { return }
        styles.remove(at: index)
    }
}

extension CharacterTier {
    public var title: String {
        switch self {
        case .normal: String(localized: "Natural", bundle: .module)
        case .freak: String(localized: "Bold", bundle: .module)
        case .total: String(localized: "Wild", bundle: .module)
        case .insects: String(localized: "Insect", bundle: .module)
        case .frogs: String(localized: "Frog", bundle: .module)
        case .cats: String(localized: "Cat", bundle: .module)
        case .dogs: String(localized: "Dog", bundle: .module)
        case .capybaras: String(localized: "Capybara", bundle: .module)
        case .birds: String(localized: "Bird", bundle: .module)
        }
    }
}

extension CharacterTier.Kind {
    public var title: String {
        switch self {
        case .human: String(localized: "Human", bundle: .module)
        case .animal: String(localized: "Animal", bundle: .module)
        }
    }
}
