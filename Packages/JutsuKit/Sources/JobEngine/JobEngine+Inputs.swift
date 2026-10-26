import Foundation
import HiggsfieldCore
import JutsuCore

// A job's inputs on their way to the provider: downloaded when only remote, prepared, then uploaded or linked.
extension JobEngine {
    /// Inputs that are only on the provider's side, from a generation made elsewhere, are downloaded first.
    func prepare(_ job: Job) async throws -> PreparedInputs {
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

    func upload(_ job: Job) async throws -> RemoteInputs {
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
}
