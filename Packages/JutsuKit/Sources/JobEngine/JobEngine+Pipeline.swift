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

    /// Inputs that are only on the provider's side, from a generation made elsewhere, are downloaded first.
    private func prepare(_ job: Job) async throws -> PreparedInputs {
        var downloaded: [URL] = []
        defer { for file in downloaded { try? FileManager.default.removeItem(at: file) } }
        var video: PreparedFile?
        if var source = job.spec.source {
            if !source.fileURL.isFileURL {
                source.fileURL = try await fetchInput(source.fileURL, named: "source", of: job.id)
                source.bookmark = nil
                downloaded.append(source.fileURL)
            }
            let (fractions, sink) = AsyncStream.makeStream(of: Double.self)
            async let forwarding: Void = forward(fractions, of: job.id)
            do {
                defer { sink.finish() }
                video = try await media.prepareVideo(source) { sink.yield($0) }
            }
            await forwarding
        }
        var images: [PreparedFile] = []
        for (index, reference) in job.spec.references.enumerated() {
            var image = reference
            if !image.fileURL.isFileURL {
                image = LocalImage(fileURL: try await fetchInput(image.fileURL, named: "image-\(index)", of: job.id))
                downloaded.append(image.fileURL)
            }
            images.append(try await media.prepareImage(image))
        }
        return PreparedInputs(video: video, images: images)
    }

    /// Downloads a remote input into the temporary folder; an earlier partial download there is resumed.
    private func fetchInput(_ url: URL, named name: String, of id: UUID) async throws -> URL {
        try await waitUntilOnline()
        let fileExtension = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jutsu-\(id.uuidString)-\(name)").appendingPathExtension(fileExtension)
        do {
            try await downloader.download(url, to: file)
        } catch JobEngineError.downloadFailed {
            throw FailureReason.inputUnavailable
        } catch JobEngineError.downloadRefused(let reason) {
            throw ProviderError.validation(field: nil, message: reason.message)
        }
        return file
    }

    /// Applies progress in the order it was reported. `prepare` waits for this before it returns,
    /// so no progress of a canceled or finished run lands later.
    private func forward(_ fractions: AsyncStream<Double>, of id: UUID) async {
        for await fraction in fractions {
            report(progress: fraction, of: id, in: .preparing)
        }
    }

    private func upload(_ job: Job) async throws -> RemoteInputs {
        if job.spec.draftJobID != nil { return RemoteInputs(video: nil, images: []) }
        if let reused = job.spec.remoteInputs { return reused }
        if Self.namesResultByJobID(job.spec) { return RemoteInputs(video: nil, images: []) }
        let files: PreparedInputs
        if let cached = prepared[job.id] {
            files = cached
        } else {
            files = try await prepare(job)
        }
        let videoCount = files.video == nil ? 0 : 1
        let total = Double(files.images.count + videoCount)
        var video: RemoteAsset?
        if let file = files.video {
            let source = job.spec.source
            if let asset = try await linked(source?.linkableOrigin, of: source?.fileURL, kind: .video, for: job) {
                video = asset
            } else {
                video = try await upload(file, for: job)
            }
            report(progress: 1 / total, of: job.id, in: .uploading)
        }
        var images: [RemoteAsset] = []
        for (index, file) in files.images.enumerated() {
            let reference = job.spec.references.indices.contains(index) ? job.spec.references[index] : nil
            if let media = reference?.serverMedia, let asset = try await networkProvider(for: job).serverAsset(media) {
                images.append(asset)
            } else if let asset = try await linked(
                reference?.linkableOrigin, of: reference?.fileURL, kind: .image, for: job)
            {
                images.append(asset)
            } else {
                images.append(try await upload(file, for: job))
            }
            report(progress: Double(images.count + videoCount) / total, of: job.id, in: .uploading)
        }
        prepared[job.id] = nil
        return RemoteInputs(video: video, images: images)
    }

    private func upload(_ file: PreparedFile, for job: Job) async throws -> RemoteAsset {
        let cutoff = clock.now.addingTimeInterval(-settings.uploadMaxAge)
        let key = Self.uploadCacheKey(file.contentHash, kind: job.providerKind, owner: job.owner)
        if let asset = try await uploadCache.asset(forContentHash: key, uploadedAfter: cutoff) {
            return asset
        }
        let asset = try await networkProvider(for: job).upload(file)
        try await uploadCache.store(asset, contentHash: key, uploadedAt: clock.now)
        return asset
    }

    /// The input as the provider takes it from the link its file was downloaded from, so it isn't uploaded; `nil`
    /// when there is no such link (`SourceClip.linkableOrigin`), the file's size can't be read or the provider
    /// needs an upload.
    private func linked(
        _ origin: URL?, of file: URL?, kind: MediaLink.Kind, for job: Job
    ) async throws
        -> RemoteAsset?
    {
        guard let origin, let file,
            let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        else { return nil }
        return try await networkProvider(for: job).linkedAsset(origin, kind: kind, byteCount: size.int64Value)
    }

    /// Uploads are reused only by the account that made them.
    static func uploadCacheKey(_ contentHash: String, kind: ProviderKind, owner: String?) -> String {
        "\(kind.rawValue)|\(owner ?? "")|\(contentHash)"
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
        await settleAgentSpend(of: sender, charged: charged)
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

    private func remoteStatus(of job: Job) async throws -> RemoteStatus {
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

    private func download(_ job: Job) async throws {
        let url: URL
        if let known = videoURLs[job.id] {
            url = known
        } else {
            // After a relaunch or a retry: the status call returns the URL again, until the result expires.
            let status: RemoteStatus
            do {
                status = try await remoteStatus(of: job)
            } catch ProviderError.validation {
                throw FailureReason.outputUnavailable
            }
            guard case .completed(let remoteURL) = status else { throw FailureReason.outputUnavailable }
            url = remoteURL
        }
        try await waitUntilOnline()
        let folder = job.downloadFolder ?? settings.outputDirectory
        if job.downloadFolder == nil { try await save(job.id) { $0.downloadFolder = folder } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = Self.partialFile(of: job.id, in: folder)
        do {
            try await fetchResult(url, to: partial, finishedAt: job.chargedAt)
        } catch ProviderError.server(status: 403) {
            // A signed URL that expired: the next try asks the status call for a fresh one.
            videoURLs[job.id] = nil
            throw ProviderError.server(status: 403)
        }
        // An operation's result keeps the sound the server gave it, in the container it came in, unless the server
        // drops the sound (`PostAction.restoresSourceSound`): it is put back as for a generation, in an MP4.
        let restoresSound = job.spec.operation?.action.restoresSourceSound ?? true
        let finished = restoresSound ? try await restoringAudio(of: job, in: partial) : partial
        let destination = try placeResult(
            finished, of: job, in: folder,
            fileExtension: job.spec.operation == nil || finished != partial
                ? nil : OutputNamePattern.resultExtension(of: url))
        if finished != partial { try? FileManager.default.removeItem(at: partial) }
        // What the job asked for isn't always what came back (a Seedance Edit ran shorter), so the file is read.
        let outputMedia = await media.outputMedia(of: destination)
        try await record(.downloaded, to: job.id) {
            $0.outputFile = destination
            $0.outputMedia = outputMedia
            $0.progress = 1
        }
    }

    /// How long Higgsfield keeps a finished result, in seconds.
    static let resultLifetime: TimeInterval = 7 * 24 * 3600

    /// Downloads a finished result into `partial`. A refusal that waiting can fix throws `ProviderError.server`
    /// and keeps the partial file, so the runner retries with backoff and resumes: 408, 429, and 403 while the
    /// result is younger than `resultLifetime` (a signed URL that expired). Any other refusal removes the partial
    /// file; 404, 410 and an old 403 mean the result expired.
    /// - Parameter finishedAt: when the generation finished; `nil` when unknown, which counts as fresh.
    func fetchResult(_ url: URL, to partial: URL, finishedAt: Date?) async throws {
        do {
            try await downloader.download(url, to: partial)
        } catch JobEngineError.downloadFailed(let status) {
            let isFresh = finishedAt.map { clock.now.timeIntervalSince($0) < Self.resultLifetime } ?? true
            switch status {
            case 408, 429:
                throw ProviderError.server(status: status)
            case 403 where isFresh:
                throw ProviderError.server(status: status)
            case 403, 404, 410:
                try? FileManager.default.removeItem(at: partial)
                throw FailureReason.outputUnavailable
            default:
                try? FileManager.default.removeItem(at: partial)
                throw ProviderError.validation(field: nil, message: Self.downloadRefusedReason(status))
            }
        } catch JobEngineError.downloadRefused(let reason) {
            try? FileManager.default.removeItem(at: partial)
            throw ProviderError.validation(field: nil, message: reason.message)
        }
    }

    static func downloadRefusedReason(_ status: Int) -> String {
        String(
            localized: "Higgsfield refused to send the result (HTTP \(status)). Retry to download it again.",
            bundle: .module)
    }

    /// The result with its sound as the job asks, or `partial` itself when nothing changes. Failing to
    /// add the sound keeps the silent result: the generation is paid for and still usable.
    private func restoringAudio(of job: Job, in partial: URL) async throws -> URL {
        let output = Self.audioFile(of: job.id, in: partial.deletingLastPathComponent())
        do {
            return try await media.restoreAudio(of: job.spec, result: partial, to: output) ? output : partial
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where Self.isOutOfSpace(error) {
            // Pauses the job, so the sound is still added once there is space again.
            throw error
        } catch {
            log.error("Job \(job.id): kept the result without source audio", detail: String(describing: error))
            return partial
        }
    }

    /// The partial file of the job's download: in the folder the download started in, or the output folder before
    /// one starts.
    func partialDownload(of id: UUID) -> URL {
        Self.partialFile(of: id, in: jobs[id]?.downloadFolder ?? settings.outputDirectory)
    }

    /// Moves a finished result into `directory` under the job's name, next to any file already there.
    /// - Parameter fileExtension: the result's own extension; `nil` for `OutputNamePattern.fileExtension`.
    func placeResult(_ file: URL, of job: Job, in directory: URL, fileExtension: String? = nil) throws -> URL {
        let name = settings.outputNamePattern.fileName(
            for: job, presetName: job.spec.presetID.flatMap(presetName), fileExtension: fileExtension)
        let free = OutputNamePattern.available(name) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return try Self.place(file, at: directory.appendingPathComponent(free))
    }

    /// Moves the finished download to `destination`. An earlier file there stays until the swap succeeds.
    static func place(_ partial: URL, at destination: URL) throws -> URL {
        try FileReplacement.move(partial, to: destination)
        return destination
    }
}
