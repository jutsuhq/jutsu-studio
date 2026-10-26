import Foundation
import JutsuCore
import Observation

/// The agents' `create_image` requests, sent through Generate…'s own runs (`ReferenceGenerator.submit`) with the
/// same guarantees as an agent's video job. Each request is recorded before anything happens. Right before the
/// submit, once the input is uploaded, the guard reads the provider's quote (else the model's list price, an
/// estimate), the person's own daily cap strictly, the agent's `max_cost` and today's agent budget
/// (`AgentSpendDecision`), then reserves the price in the agent spend ledger and saves the record as possibly sent.
/// Once the person approved it, a price above the one they approved holds it again. Over any limit, with an unknown
/// price or a ledger that can't be written, nothing is sent and the request is held in
/// the Queue for the person. A reservation is released only when the submit certainly never went out (stopped before
/// it, or refused by the provider); a submit cut off or unanswered keeps it, as does a cancel the provider refused.
/// Once every job of an accepted request has ended, the jobs Higgsfield doesn't bill (failed, refused by moderation,
/// cancelled) stop counting their share, so the request counts what its images that were made cost.
@MainActor
@Observable
public final class AgentImageQueue {
    @ObservationIgnored let generator: ReferenceGenerator
    @ObservationIgnored let ledger: any AgentSpendLedger
    @ObservationIgnored let dailyLimit: @MainActor (ProviderKind) -> Int
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private let file: LogFile<AgentImageRecord>
    @ObservationIgnored private var loaded: [AgentImageRecord]?
    @ObservationIgnored let log = PresentationLog(category: "AgentImages")

    static let keptDays = 30

    /// - Parameters:
    ///   - folder: `nil` keeps it in memory, for tests.
    ///   - dailyLimit: the person's daily agent budget for a connection, in its unit.
    public init(
        folder: URL?, generator: ReferenceGenerator, ledger: any AgentSpendLedger,
        dailyLimit: @escaping @MainActor (ProviderKind) -> Int, now: @escaping @Sendable () -> Date = Date.init
    ) {
        file = LogFile(folder: folder, name: "agent-images.json")
        self.generator = generator
        self.ledger = ledger
        self.dailyLimit = dailyLimit
        self.now = now
        generator.onRunEnded = { [weak self] id, state in self?.ended(id, state) }
    }

    // MARK: Records

    /// Every request kept, newest first. Throws when the file can't be read: nothing is taken then.
    public func records() throws(LogWriteError) -> [AgentImageRecord] {
        try load().sorted { AgentCursor.isNewerFirst(($0.createdAt, $0.id), ($1.createdAt, $1.id)) }
    }

    public func record(_ id: UUID) -> AgentImageRecord? {
        (try? load())?.first { $0.id == id }
    }

    private func load() throws(LogWriteError) -> [AgentImageRecord] {
        if let loaded { return loaded }
        let records = try file.readStrict()
        loaded = records
        return records
    }

    private func save(_ record: AgentImageRecord) throws(LogWriteError) {
        var records = try load()
        records.removeAll { $0.id == record.id }
        records.append(record)
        let cutoff = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        records.removeAll { $0.isOver && ($0.finishedAt ?? $0.createdAt) < cutoff }
        try file.write(records)
        loaded = records
    }

    /// Saves a change that isn't money: a write that fails keeps it for this launch.
    private func update(_ id: UUID, _ change: (inout AgentImageRecord) -> Void) {
        guard var record = record(id) else { return }
        change(&record)
        do {
            try save(record)
        } catch {
            log.error("Image request \(id): a change can't be saved", detail: String(describing: error))
            if let index = loaded?.firstIndex(where: { $0.id == id }) { loaded?[index] = record }
        }
    }

    // MARK: Requests

    /// Takes a request: checked as the form would check it, recorded, then sent through the guard. Returns its record.
    /// - Parameter id: the run's ID, chosen by the caller and recorded with the agent's `request_id` first.
    public func create(
        _ order: AgentImageOrder, id: UUID, origin: AgentOrigin, provider: any ImageProvider,
        upload: @escaping @Sendable (LocalImage) async throws -> RemoteAsset
    ) throws(AgentImageRefusal) -> AgentImageRecord {
        let draft = try order.draft(models: generator.models, modelsAreSaved: generator.modelsAreSaved).get()
        let record = AgentImageRecord(
            id: id, origin: origin, providerKind: provider.kind, owner: provider.owner, model: draft.model,
            prompt: draft.prompt, aspectRatio: draft.aspectRatio, count: draft.count, input: draft.inputs.first,
            severalInputs: draft.inputs.count > 1 ? draft.inputs : nil, state: .pricing, priceIsKnown: false,
            createdAt: now(), title: draft.title)
        do {
            try save(record)
        } catch {
            throw AgentImageRefusal(error.localizedDescription, isNotSaved: true)
        }
        showRun(record, state: .running)
        send(record, provider: provider, upload: upload)
        return record
    }

    /// The person's Send on a held request: it goes out at the price they saw, past the agent's limits but still
    /// under their own daily cap unless that price was over it too. Nothing happens to a request that isn't held.
    public func approve(
        _ id: UUID, provider: any ImageProvider, upload: @escaping @Sendable (LocalImage) async throws -> RemoteAsset
    ) {
        guard var record = record(id), record.state == .held, !record.mayHaveBeenSent,
            record.providerKind == provider.kind, record.owner == provider.owner
        else { return }
        record.origin.approvedByPerson = true
        record.approvedPrice = record.price
        record.hold = nil
        record.state = .pricing
        do {
            try save(record)
        } catch {
            return generator.finish(id, .failed(error.localizedDescription))
        }
        showRun(record, state: .running)
        send(record, provider: provider, upload: upload)
    }

    /// Stops a request. One held or still being priced was never sent; one sent is cancelled as Generate… cancels
    /// its own, and its reservation stays. Returns `false` for a request that is already over.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        guard let record = record(id), !record.isOver else { return false }
        if record.state == .held, generator.submits[id] == nil, !generator.runs.contains(where: { $0.id == id }) {
            // Held at an earlier launch and not shown again: nothing runs it.
            generator.onRunEnded?(id, .canceled)
        } else {
            generator.cancel(id)
        }
        return true
    }

    /// At launch, before anything is followed again: gives back reservations a crash orphaned (saved to the ledger,
    /// never saved with their request, so never sent), fails a request that was being sent and whose answer was lost
    /// (its reservation stays), and shows the held ones again.
    public func restore() async {
        let records: [AgentImageRecord]
        do {
            records = try load()
        } catch {
            return log.error(
                "The agent image requests can't be read to restore them", detail: String(describing: error))
        }
        do {
            for spend in try await ledger.unsettled() {
                guard let record = records.first(where: { $0.id == spend.jobID }),
                    record.origin.reservation != spend.id
                else { continue }
                await release(spend.id, of: record.id)
            }
        } catch {
            // Reservations kept, which only counts too much.
            log.error(
                "The agent spend ledger can't be read to reconcile image requests", detail: String(describing: error))
        }
        for record in records {
            let followed = generator.jobLog.records.contains { $0.runID == record.id }
            switch record.state {
            case .held:
                showRun(record, state: .held(Self.text(of: record.hold ?? .agent(.unknownPrice))))
            case .sending where followed:
                update(record.id) { $0.state = .following }
            case .sending:
                update(record.id) {
                    $0.state = .failed
                    $0.error = Self.lostAnswer
                    $0.finishedAt = now()
                }
            case .following where !followed:
                // Its jobs ended and were forgotten before the record heard: its images are in Library › Images.
                update(record.id) {
                    $0.state = .finished
                    $0.finishedAt = now()
                }
            default:
                break
            }
        }
    }

    /// A connection: requests of its account that were taken but never priced are sent now, and the requests it
    /// follows again show which agent asked for them. Call after `ReferenceGenerator.resume`.
    public func resume(
        provider: any ImageProvider, upload: @escaping @Sendable (LocalImage) async throws -> RemoteAsset
    ) {
        let records: [AgentImageRecord]
        do {
            records = try load()
        } catch {
            return log.error("The agent image requests can't be read to resume them", detail: String(describing: error))
        }
        for record in records where record.providerKind == provider.kind && record.owner == provider.owner {
            switch record.state {
            case .pricing where generator.submits[record.id] == nil:
                showRun(record, state: .running)
                send(record, provider: provider, upload: upload)
            case .following, .held:
                if let index = generator.runs.firstIndex(where: { $0.id == record.id }) {
                    generator.runs[index].agent = record.origin
                    generator.runs[index].price = record.price
                }
            default:
                break
            }
        }
    }

    /// The images a request made that are saved in Library › Images, as far as this session's results know.
    public func files(of id: UUID) -> [URL] {
        generator.images.filter { $0.variantGroupID == id }.compactMap(\.fileURL)
    }
}

// The guard around each submit.
extension AgentImageQueue {
    private func showRun(_ record: AgentImageRecord, state: ImageRun.State) {
        var run = ImageRun(id: record.id, model: record.model.title, count: record.count, state: state)
        run.agent = record.origin
        run.price = record.price
        run.name = record.title
        if let index = generator.runs.firstIndex(where: { $0.id == record.id }) {
            generator.runs[index] = run
        } else {
            generator.runs.insert(run, at: 0)
        }
    }

    private func send(
        _ record: AgentImageRecord, provider: any ImageProvider,
        upload: @escaping @Sendable (LocalImage) async throws -> RemoteAsset
    ) {
        let id = record.id
        let hook = AgentImageSubmit(
            clear: { [weak self] request in
                await self?.clear(id, request: request, provider: provider)
            },
            answered: { [weak self] outcome in
                await self?.answered(id, outcome)
            })
        let draft = record.draft
        generator.submits[id] = Task { [weak generator] in
            await generator?.submit(
                id, draft: draft, cost: .unknownCredits, provider: provider, upload: upload, agent: hook)
        }
    }

    /// The guard, right before the submit: the price to send at, or `nil` once the request is held or failed.
    private func clear(_ id: UUID, request: ImageRequest, provider: any ImageProvider) async -> Cost? {
        guard let record = record(id) else {
            generator.finish(id, .failed(Self.notRecorded))
            return nil
        }
        guard let (price, isKnown) = await quoteOrFail(request, of: record, provider: provider) else { return nil }
        let status: SpendStatus?
        do {
            status = try await generator.spendStatus(provider.kind)
        } catch {
            generator.finish(id, .failed(ReferenceGenerator.message(error)))
            return nil
        }
        if let status, let cap = status.cap,
            case .needsConfirmation = Budget.allows(cost: price, committedToday: status.committedToday, cap: cap),
            !Budget.covers(approved: record.approvedPrice, price)
        {
            return hold(id, .priceAboveCap, price: price, isKnown: isKnown)
        }
        // Image requests are always sent without the plan's unlimited allowance (`use_unlim` false), so each one
        // counts against the budget like any paid request and Let agents use unlimited generations never applies.
        let decision = AgentSpendDecision.decide(
            price: price, isKnown: isKnown, origin: record.origin, dailyLimit: dailyLimit(provider.kind),
            paysUnlimited: false, approved: record.approvedPrice)
        switch decision {
        case .hold(let reason):
            return hold(id, .agent(reason), price: price, isKnown: isKnown)
        case .send(let money, let limit):
            return await reserve(record, money: money, limit: limit, price: price, isKnown: isKnown)
        }
    }

    /// The provider's quote for the request, else the model's list price as an estimate; and whether it is exact.
    /// A quote that turns the request down, such as more input images than a model whose catalog states no limit
    /// takes, fails the request (`nil`): it comes before anything is reserved or sent, so the refusal costs nothing.
    private func quoteOrFail(
        _ request: ImageRequest, of record: AgentImageRecord, provider: any ImageProvider
    ) async -> (Cost, Bool)? {
        do {
            let price = try await provider.imageEstimate(request)
            return (price, !price.isEstimate && !price.isUnknownPrice)
        } catch {
            if let error = error as? ProviderError, case .validation = error {
                generator.finish(record.id, .failed(ReferenceGenerator.message(error)))
                return nil
            }
            return (Self.listPrice(of: record) ?? .unknownCredits, false)
        }
    }

    /// Reserves the price in the ledger, then saves the request as possibly sent; held or failed (`nil`) otherwise.
    private func reserve(
        _ record: AgentImageRecord, money: AgentMoney, limit: Int?, price: Cost, isKnown: Bool
    ) async -> Cost? {
        let id = record.id
        let spend = AgentSpend(jobID: id, money: money, at: now())
        do {
            guard try await ledger.reserve(spend, dailyLimit: limit) else {
                return hold(id, .agent(.overDailyBudget), price: price, isKnown: isKnown)
            }
        } catch {
            log.error("Image request \(id): the agent spend ledger can't be written", detail: String(describing: error))
            return hold(id, .agent(.ledgerUnavailable), price: price, isKnown: isKnown)
        }
        var sending = record
        sending.origin.reservation = spend.id
        sending.sentAt = now()
        sending.state = .sending
        sending.price = price
        sending.priceIsKnown = isKnown
        do {
            try save(sending)
        } catch {
            // Not recorded as sent, so it isn't sent.
            log.error("Image request \(id): can't be recorded as sent", detail: String(describing: error))
            await release(spend.id, of: id)
            generator.finish(id, .failed(error.localizedDescription))
            return nil
        }
        if let index = generator.runs.firstIndex(where: { $0.id == id }) { generator.runs[index].price = price }
        return price
    }

    private func hold(_ id: UUID, _ reason: AgentImageRecord.Hold, price: Cost, isKnown: Bool) -> Cost? {
        update(id) {
            $0.state = .held
            $0.hold = reason
            $0.price = price
            $0.priceIsKnown = isKnown
        }
        if let index = generator.runs.firstIndex(where: { $0.id == id }) {
            generator.runs[index].state = .held(Self.text(of: reason))
            generator.runs[index].price = price
        }
        return nil
    }

    private func answered(_ id: UUID, _ outcome: AgentImageSubmit.Outcome) async {
        guard let reservation = record(id)?.origin.reservation else { return }
        switch outcome {
        case .accepted:
            update(id) { $0.state = .following }
            do {
                try await ledger.settle(reservation, amount: nil)
            } catch {
                // Still reserved, which counts the same.
                log.error("Image request \(id): its charge can't be recorded", detail: String(describing: error))
            }
        case .refused, .notSent:
            // Certainly never sent: its reservation is given back.
            guard await release(reservation, of: id) else { return }
            update(id) {
                $0.origin.reservation = nil
                $0.sentAt = nil
            }
        case .unknown:
            break
        }
    }

    /// A run ended or stopped being followed.
    private func ended(_ id: UUID, _ state: ImageRun.State) {
        guard let record = record(id), !record.isOver else { return }
        switch state {
        case .finished:
            settle(record)
            update(id) {
                $0.state = .finished
                $0.finishedAt = now()
            }
        case .failed(let message):
            settle(record)
            update(id) {
                $0.state = .failed
                $0.error = message
                $0.finishedAt = now()
            }
        case .canceled:
            settle(record)
            update(id) {
                $0.state = .canceled
                $0.finishedAt = now()
            }
        case .running, .held, .interrupted:
            break
        }
    }
}

// The reservations of requests that ended or were never sent.
extension AgentImageQueue {
    /// Settles an accepted request's reservation to what its jobs were really charged once they all ended: Higgsfield
    /// doesn't bill a job that failed, was refused by moderation or was cancelled, so each of those stops counting its
    /// share (the price for its images). The full reservation stays while any job's outcome is unknown: still pending
    /// when following stopped, or a cancel the provider refused. Read from the job log before the run forgets it.
    private func settle(_ record: AgentImageRecord) {
        guard let reservation = record.origin.reservation else { return }
        let jobs = generator.jobLog.records.filter { $0.runID == record.id }
        guard !jobs.isEmpty, !jobs.contains(where: { $0.state == .pending }) else { return }
        let unbilled = jobs.filter(\.isUnbilled).map(\.id)
        guard !unbilled.isEmpty else { return }
        let (ledger, log, id) = (ledger, log, record.id)
        Task {
            // A ledger that can't be written keeps the reservation, which only counts too much.
            for part in unbilled {
                do {
                    try await ledger.unbill(reservation, part: part, of: jobs.count)
                } catch {
                    log.error(
                        "Image request \(id): an unbilled job can't be recorded", detail: String(describing: error))
                }
            }
        }
    }

    /// Gives back a reservation whose submit certainly never went out; `false` when the ledger can't be written,
    /// which keeps it and only counts too much.
    @discardableResult
    private func release(_ reservation: UUID, of id: UUID) async -> Bool {
        do {
            try await ledger.release(reservation)
            return true
        } catch {
            log.error("Image request \(id): a reservation can't be released", detail: String(describing: error))
            return false
        }
    }
}
