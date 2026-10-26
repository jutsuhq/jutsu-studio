import Foundation
import HiggsfieldCore
import JutsuCore

// One job's way through the pipeline: prepare → upload → slot → submit → poll → download.
extension JobEngine {
    func drive(_ id: UUID, token: UUID) async {
        var retryDelay = Backoff.retrying(settings)
        while !Task.isCancelled, let job = jobs[id], job.state.isRunnable {
            do {
                try await step(job)
                retryDelay.reset()
            } catch {
                guard await recover(from: error, of: id, delay: &retryDelay) else { break }
            }
        }
        await releaseSlot(id)
        prepared[id] = nil
        videoURLs[id] = nil
        if runners[id]?.token == token { runners[id] = nil }
    }

    /// Does the work of the job's current state and moves it on.
    private func step(_ job: Job) async throws {
        switch job.state {
        case .preparing:
            try Self.checkReusedInputs(job.spec)
            let uploads = job.spec.remoteInputs == nil && !Self.uploadsNothing(job.spec)
            prepared[job.id] = uploads ? try await prepare(job) : nil
            try await apply(.prepared, to: job.id)
        case .uploading:
            let inputs = try await upload(job)
            try await apply(.uploaded, to: job.id) { $0.inputs = inputs }
        case .waitingForSlot:
            try await submit(job)
        case .queued, .processing:
            try await poll(job.id)
        case .downloading:
            try await download(job)
        case .done, .failed, .rejected, .canceled, .paused:
            return
        }
    }

    /// Resubmits always carry the job's one idempotency key, so a lost response can't charge twice. A provider
    /// that can't send it gets one submit: an attempt still marked after a quit, crash or pause fails as unknown.
    private func submit(_ job: Job) async throws {
        if job.submitAttempt?.isIdempotent == false {
            try await apply(.failed(reason: .submitCutOff), to: job.id)
            return
        }
        let inputs: RemoteInputs
        if let saved = job.inputs {
            inputs = saved
        } else {
            inputs = try await upload(job)
        }
        guard try await priceFitsCap(job.id, inputs: inputs) else { return }
        try await acquireSlot(job.id)
        let provider = try await networkProvider(for: job)
        let isIdempotent = try await provider.submitIsIdempotent(job.spec)
        // A pause or cancel that lands here must not leave a submit marker for a request never sent.
        try Task.checkCancellation()
        // An agent's job passes its spending guard and reserves its price before anything is sent.
        guard case .send(let reservation) = try await clearAgentSpend(job.id, inputs: inputs) else { return }
        // A stopping engine sends nothing new; the job submits on the next start.
        try await beginSubmit(job.id, isIdempotent: isIdempotent, reservation: reservation)
        defer { submits.finish(job.id) }
        var remote: RemoteJob
        do {
            remote = try await provider.submit(job.spec, inputs: inputs, idempotencyKey: job.idempotencyKey)
        } catch let error as ProviderError where error != .outcomeUnknown {
            if try await settleFailedSubmit(error, of: job, inputs: inputs, isIdempotent: isIdempotent) { return }
            throw error
        }
        let initialStatus = remote.initialStatus
        let (paidWithUnlimited, charged) = (remote.paidWithUnlimited, remote.charged)
        let variants = remote.variants
        remote.initialStatus = nil
        remote.paidWithUnlimited = false
        remote.charged = nil
        remote.variants = []
        var share: VariantShare?
        // The job as saved now, with the server price `priceFitsCap` may have added. Every job the answer names is
        // paid for, so they are tracked even if that copy is gone.
        let sender = jobs[job.id] ?? job
        if sender.spec.variants > 1 || !variants.isEmpty {
            share = await startVariants(variants, of: sender, inputs: inputs, paidWithUnlimited: paidWithUnlimited)
        }
        // Sent for the allowance and not paid by it: the charge counts, or the job's price when the answer can't say.
        let unpaid = sender.spec.usesUnlimited && !paidWithUnlimited
        await settleAgentSpend(of: sender, charged: charged ?? (unpaid ? sender.price : nil))
        try await record(.submitted, to: job.id) { [remote, share] in
            share?.apply(to: &$0)
            // Sent without the allowance, or the answer says it cost credits: the cap counts it from now on.
            if !paidWithUnlimited { $0.spec.usesUnlimited = false }
            if let charged { $0.serverPrice = charged }
            $0.inputs = inputs
            $0.remote = remote
            $0.submitAttempt = nil
            $0.submittedAt = clock.now
        }
        // A submit answered with a final state needs no poll to act on it.
        if let initialStatus { try await handle(initialStatus, of: job.id) }
    }

    /// Asks the provider for its price of the exact request before it is paid for, then checks it against the
    /// daily cap. Returns `false` when the job paused because that price needs the user. Without a quote the
    /// preliminary price stands. A submit that may already have reached the server is resent unchecked, and a job
    /// paid from the unlimited allowance isn't quoted: the cap doesn't count it.
    private func priceFitsCap(_ id: UUID, inputs: RemoteInputs) async throws -> Bool {
        var job = try await loadJob(id)
        guard job.submitAttempt == nil, !job.spec.usesUnlimited else { return true }
        if job.serverPrice == nil {
            let provider = try await networkProvider(for: job)
            do {
                if let price = try await provider.serverEstimate(job.spec, inputs: inputs) {
                    try await save(id) { $0.serverPrice = price }
                    job.serverPrice = price
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error(
                    "Job \(id): no server estimate, keeping the preliminary price", detail: String(describing: error))
            }
        }
        let status = try await spendStatus(job)
        guard let price = job.serverPrice, let status else { return true }
        guard
            Budget.refinedPriceNeedsConfirmation(
                preliminary: job.cost, refined: price, approved: job.approvedPrice,
                committedToday: status.committedToday, cap: status.cap)
        else { return true }
        try await apply(.paused(.priceAboveCap), to: id) { $0.inputs = inputs }
        return false
    }

    /// Unknown statuses read as in progress, so only the deadline ends a job the provider never finishes.
    /// It fails without a resubmit: the generation may still finish, and be charged, on the provider's side.
    private func poll(_ id: UUID) async throws {
        await occupySlot(id)
        var delay = Backoff.polling(settings)
        var last: RemoteStatus?
        let started = jobs[id].flatMap { $0.checkedAgainAt ?? $0.submittedAt } ?? clock.now
        while let job = jobs[id], job.state.isQueuedOrProcessing {
            let status: RemoteStatus
            if pollsInBatch(job) {
                switch try await batchedStatus(of: id) {
                case .status(let answer): status = answer
                case .alone: status = try await remoteStatus(of: job)
                }
            } else {
                try await clock.sleep(for: delay.next())
                status = try await remoteStatus(of: job)
            }
            if jobs[id]?.retrying != nil { try await save(id) { $0.retrying = nil } }
            if status != last { delay.reset() }
            last = status
            try await handle(status, of: id)
            if let state = jobs[id]?.state, state.isQueuedOrProcessing,
                clock.now.timeIntervalSince(started) >= settings.generationDeadline
            {
                try await failAtDeadline(id)
            }
        }
    }

    func remoteStatus(of job: Job) async throws -> RemoteStatus {
        guard let remote = job.remote else { throw JobEngineError.missingRequestID }
        return try await networkProvider(for: job).status(remote)
    }

    private func handle(_ status: RemoteStatus, of id: UUID) async throws {
        switch status {
        case .queued:
            return
        case .inProgress:
            // A job checked again after the deadline keeps the start an earlier poll saw.
            if jobs[id]?.state == .queued {
                try await apply(.started, to: id) { $0.processingAt = $0.processingAt ?? clock.now }
            }
        case .completed(let url):
            videoURLs[id] = url
            await releaseSlot(id)
            try await apply(.completed, to: id) { $0.chargedAt = clock.now }
            try await readCharge(of: id)
        // Higgsfield doesn't bill a generation that failed, was refused or was cancelled: the agent's share goes back.
        case .failed(let message):
            await releaseSlot(id)
            try await apply(.failed(reason: message.map(FailureReason.message) ?? .generationFailed), to: id)
            await unbillAgentSpend(of: id)
        case .rejected(let reason):
            await releaseSlot(id)
            try await apply(.rejected, to: id) { $0.rejection = reason }
            await unbillAgentSpend(of: id)
        case .canceled:
            await releaseSlot(id)
            let cancellable = jobs[id]?.state.isCancellable == true
            try await apply(cancellable ? .cancel : .failed(reason: .canceledOnServer), to: id)
            await unbillAgentSpend(of: id)
        }
    }

    /// A job queued without a price (`Job.priceIsUnknown`, a Topaz upscale) gets what the provider says it charged
    /// once it has finished. Without an answer, or when the answer fails, the price stays unknown and the download
    /// goes on.
    private func readCharge(of id: UUID) async throws {
        guard let job = jobs[id], job.priceIsUnknown, let provider = try? currentProvider(for: job) else { return }
        let charged: Cost?
        do {
            charged = try await provider.charge(of: job)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("Job \(id): couldn't read what it was charged", detail: String(describing: error))
            return
        }
        guard let charged else { return }
        try await save(id) { $0.serverPrice = charged }
    }
}
