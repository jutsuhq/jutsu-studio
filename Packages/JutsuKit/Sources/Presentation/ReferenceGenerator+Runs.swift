import Foundation
import JutsuCore

/// What an agent's request adds to a submit (`AgentImageQueue`): its spending guard, and how the submit went.
struct AgentImageSubmit {
    enum Outcome {
        /// Stopped before the submit went out.
        case notSent
        /// The provider turned it down, so it never started.
        case refused
        /// Cut off or unanswered: it may have started.
        case unknown
        case accepted
    }

    /// Runs once the request is built, right before its price is written and it is sent: the price to send it at,
    /// or `nil` when the guard held or failed it and nothing may go out.
    var clear: (ImageRequest) async -> Cost?
    var answered: (Outcome) async -> Void
}

/// Sending a request and following its jobs until they end.
extension ReferenceGenerator {
    /// - Parameter agent: an agent's request: its spending guard runs once the request is built, and is told how the
    ///   submit went; `nil` for the person's own.
    func submit(
        _ id: UUID, draft: Draft, cost: Cost, provider: any ImageProvider,
        upload: (LocalImage) async throws -> RemoteAsset, agent: AgentImageSubmit? = nil
    ) async {
        defer { submits[id] = nil }
        let request: ImageRequest
        do {
            request = try await self.request(draft, upload: upload)
            try Task.checkCancellation()
        } catch {
            return finish(id, error is CancellationError ? .canceled : .failed(Self.message(error)))
        }
        var cost = cost
        if let agent {
            // The guard holds or fails the run itself when it lets nothing through.
            guard let cleared = await agent.clear(request) else { return }
            cost = cleared
            if Task.isCancelled {
                await agent.answered(.notSent)
                return finish(id, .canceled)
            }
        }
        do {
            try spend.add(
                ImageCharge(
                    id: id, date: now(), cost: cost, providerKind: provider.kind, model: draft.model.title,
                    images: draft.count))
        } catch {
            await agent?.answered(.notSent)
            return finish(id, .failed(ImageSpendLog.notSent(error)))
        }
        let jobs: [RemoteJob]
        do {
            jobs = try await provider.submitImages(request, idempotencyKey: id)
        } catch {
            // A submit cut off or unanswered may have started the request, so its price keeps counting.
            if Self.wasRefused(error) {
                spend.remove(id)
                await agent?.answered(.refused)
            } else {
                spend.settle(id)
                await agent?.answered(.unknown)
            }
            return finish(id, error is CancellationError ? .canceled : .failed(Self.message(error)))
        }
        await agent?.answered(.accepted)
        logJobs(jobs, of: id, draft: draft, request: request, provider: provider)
        // Cancelled while the answer was on its way: the jobs it started are cancelled in turn.
        if Task.isCancelled { canceling.insert(id) }
        follow(id, provider: provider)
    }

    /// Writes the jobs a submit started to the job log, so they are followed again after a relaunch.
    private func logJobs(
        _ jobs: [RemoteJob], of id: UUID, draft: Draft, request: ImageRequest, provider: any ImageProvider
    ) {
        let date = now()
        jobLog.add(
            jobs.map {
                var record = ImageJobRecord(
                    job: $0, owner: provider.owner, runID: id, createdAt: date, prompt: draft.prompt,
                    model: draft.model.title, aspectRatio: draft.aspectRatio, count: draft.count)
                record.providerKind = provider.kind
                record.request = request
                record.inputImages = draft.inputs
                record.title = draft.title
                return record
            })
    }

    /// Follows the requests of `provider`'s connection that were still running, as after a relaunch, a new sign-in
    /// or a poll that couldn't be read.
    public func resume(provider: any ImageProvider) {
        let pending = jobLog.pending(of: provider.owner)
        for run in Set(pending.map(\.runID)) where followers[run] == nil && submits[run] == nil {
            guard let first = pending.first(where: { $0.runID == run }) else { continue }
            if let index = runs.firstIndex(where: { $0.id == run }) {
                runs[index].state = .running
            } else {
                runs.insert(ImageRun(id: run, model: first.model, count: first.count, state: .running), at: 0)
            }
            follow(run, provider: provider)
        }
    }

    /// A new connection: the old one's upload and price are dropped, so nothing of one account reaches another, and
    /// its requests stop being followed until that account is connected again (`resume`). Submits already sent are
    /// left to be answered.
    public func reset() {
        generation += 1
        uploaded = nil
        price = nil
        priceFailure = nil
        for (run, task) in followers {
            task.cancel()
            finish(run, .interrupted(Self.waitsForAccount))
        }
        followers = [:]
    }

    private func follow(_ run: UUID, provider: any ImageProvider) {
        followers[run] = Task { [weak self] in
            await self?.poll(run, provider: provider)
        }
    }

    /// How one round of polls went.
    private enum PollRound {
        case read
        /// Following stopped: cancelled, by the user or for another connection.
        case stopped
        /// A status that can't be read, for a reason waiting doesn't fix.
        case interrupted(any Error)
    }

    /// Polls until every job of the run ended, backing off like the engine (`Backoff.polling`). Errors that
    /// waiting can fix are polled through. Any other leaves the jobs pending and the price counted: a status that
    /// can't be read says nothing about the job, which may still finish and be charged.
    private func poll(_ run: UUID, provider: any ImageProvider) async {
        var delay = Backoff.polling()
        var interruption: (any Error)?
        while !Task.isCancelled, !canceling.contains(run) {
            let round = await pollOnce(run, provider: provider)
            if case .interrupted(let error) = round { interruption = error }
            guard case .read = round, jobLog.records.contains(where: { $0.runID == run && $0.state == .pending })
            else { break }
            do {
                try await sleep(.seconds(delay.next()))
            } catch {
                break
            }
        }
        await stopPolling(run, interruption: interruption, provider: provider)
    }

    private func pollOnce(_ run: UUID, provider: any ImageProvider) async -> PollRound {
        for record in jobLog.records where record.runID == run && record.state == .pending {
            let status: ImageJobStatus
            do {
                status = try await provider.imageStatus(record.job)
            } catch let error as ProviderError where error.isTransient {
                continue
            } catch is CancellationError {
                return .stopped
            } catch {
                return .interrupted(error)
            }
            // A poll answered after the run stopped being followed is read again by whoever follows it next.
            guard !Task.isCancelled else { return .stopped }
            apply(status, to: record)
        }
        return .read
    }

    private func stopPolling(_ run: UUID, interruption: (any Error)?, provider: any ImageProvider) async {
        if canceling.remove(run) != nil {
            followers[run] = nil
            // In a task of its own: this one is cancelled, and would cut the cancel requests off.
            await Task { [weak self] in await self?.cancelJobs(of: run, provider: provider) }.value
            return
        }
        // Stopped for another connection: `resume` follows it again.
        guard !Task.isCancelled else { return }
        followers[run] = nil
        if let interruption {
            if interruption as? ProviderError == .unauthorized { onSignInExpired?() }
            return finish(run, .interrupted(Self.interrupted(by: interruption)))
        }
        end(run)
    }

    private func apply(_ status: ImageJobStatus, to record: ImageJobRecord) {
        switch status {
        case .pending:
            break
        case .completed(let urls):
            jobLog.update(record.id, state: .completed)
            let new = urls.enumerated().map { offset, url in
                var image = GeneratedImage(
                    url: url, prompt: record.prompt, model: record.model, aspectRatio: record.aspectRatio)
                image.remote = MaterialRemote(
                    provider: record.providerKind, owner: record.owner, id: record.id, output: offset)
                image.parameters = record.request.flatMap { try? JSONEncoder().encode($0) }
                image.inputImages = record.inputImages
                image.variantGroupID = record.runID
                image.title = record.title
                return image
            }
            images.insert(contentsOf: new, at: 0)
            onImages?(new)
        case .failed(let message):
            jobLog.update(record.id, state: .failed(message))
        case .rejected:
            jobLog.update(record.id, state: .rejected)
        case .canceled:
            jobLog.update(record.id, state: .canceled)
        }
    }

    /// Every job of the run ended: charged when one made images, else taken off.
    private func end(_ run: UUID) {
        let records = jobLog.records.filter { $0.runID == run }
        if records.contains(where: { $0.state == .completed }) {
            spend.settle(run)
            finish(run, .finished)
        } else {
            spend.remove(run)
            finish(run, Self.failure(of: records).map(ImageRun.State.failed) ?? .canceled)
        }
        jobLog.forget(run: run)
    }

    /// A request cancelled while queued isn't charged; one the provider can't cancel any more is, so its price
    /// stays counted, as does one that already made images. Each job cancelled is marked so before the run ends, so
    /// `onRunEnded` sees which ones went unbilled.
    private func cancelJobs(of run: UUID, provider: any ImageProvider) async {
        var refused = false
        for record in jobLog.records where record.runID == run && record.state == .pending {
            do {
                try await provider.cancelImages(record.job)
                jobLog.update(record.id, state: .canceled)
            } catch {
                refused = true
            }
        }
        let made = jobLog.records.contains { $0.runID == run && $0.state == .completed }
        if refused || made { spend.settle(run) } else { spend.remove(run) }
        finish(run, made ? .finished : .canceled)
        jobLog.forget(run: run)
    }

    private static func failure(of records: [ImageJobRecord]) -> String? {
        for record in records {
            switch record.state {
            case .rejected:
                return String(localized: "Higgsfield's content check refused the prompt.", bundle: .module)
            case .failed(let message):
                return message ?? couldNotMake
            default:
                continue
            }
        }
        return nil
    }

    /// The server turned the request down, so it never started.
    static func wasRefused(_ error: any Error) -> Bool {
        switch error as? ProviderError {
        case .unauthorized?, .insufficientFunds?, .concurrencyLimit?, .validation?, .modelUnavailable?, .rejected?:
            true
        default:
            false
        }
    }

    static let couldNotMake = String(localized: "Higgsfield couldn't make the image.", bundle: .module)
    static let waitsForAccount = String(
        localized: "Followed again when the account that sent it is connected. Its price still counts.",
        bundle: .module)

    static func interrupted(by error: any Error) -> String {
        if error as? ProviderError == .unauthorized {
            return String(
                localized: "Connect Higgsfield again to keep following this request. Its price still counts.",
                bundle: .module)
        }
        return String(
            localized: """
                Can't read where this request is: \(message(error)) It's followed again after the next sign-in or \
                launch, and its price still counts.
                """, bundle: .module)
    }
}

extension ProviderError {
    /// A poll that failed for a reason waiting can fix.
    var isTransient: Bool {
        switch self {
        case .network, .server, .modelUnavailable, .concurrencyLimit: true
        default: false
        }
    }
}
