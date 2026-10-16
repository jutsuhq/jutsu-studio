import Foundation

/// A provider that can list what its account generated, including outside the app.
public protocol GenerationHistory: Sendable {
    /// One page of finished videos the app can run again, newest first; `nil` for the first page.
    func history(after cursor: HistoryCursor?) async throws -> HistoryPage
}

/// Where the next page starts. Opaque: only the provider that returned it reads it.
public struct HistoryCursor: Sendable, Hashable {
    public var value: String

    public init(_ value: String) {
        self.value = value
    }
}

public struct HistoryPage: Sendable, Hashable {
    /// Only the items the app can show; a page may hold none while later pages still do.
    public var items: [HistoryItem]
    /// Finished image generations the app can show, newest first.
    public var images: [HistoryImageItem]
    /// `nil` on the last page.
    public var nextCursor: HistoryCursor?

    public init(items: [HistoryItem], images: [HistoryImageItem] = [], nextCursor: HistoryCursor?) {
        self.items = items
        self.images = images
        self.nextCursor = nextCursor
    }
}

/// A finished generation from the account's history, in the app's terms.
public struct HistoryItem: Sendable, Hashable, Identifiable {
    /// The provider's job ID, as `RemoteJob.requestID` holds it for jobs the app submitted.
    public var id: String
    /// The library item this becomes once imported; kept across reloads of the history.
    public var jobID: UUID
    public var mode: Mode
    public var model: VideoModel
    public var createdAt: Date
    /// Liked on the provider's side; the library's star for the item, kept in step with it.
    public var isLiked: Bool
    public var outputURL: URL
    /// The output's length in seconds and frame size as the provider's params state them; `nil` when it didn't say.
    /// Only a hint until the file is downloaded: the params can be wrong (a Seedance Edit said 854×480 and 5 s of a
    /// 480×854, 3.71 s file), so an import reads the file's own (`Job.outputMedia`).
    public var duration: TimeInterval?
    public var pixelSize: PixelSize?
    public var resolution: Resolution?
    public var prompt: String
    /// The uploaded source video and reference images, reusable by media ID while the provider keeps them.
    public var inputs: RemoteInputs
    /// Seedance's native draft (`draft: true` in its params): imported as a draft that can be finalized at 1080p
    /// within seven days of `createdAt` (`RemoteJob.isNativeDraft`).
    public var isNativeDraft = false
    /// The draft this generation finalized (`draft_job_id` in its params), kept on the imported job's spec
    /// (`JobSpec.draftJobID`); `nil` for any other.
    public var draftJobID: String?

    public init(
        id: String, jobID: UUID = UUID(), mode: Mode, model: VideoModel, createdAt: Date, isLiked: Bool = false,
        outputURL: URL, duration: TimeInterval? = nil, pixelSize: PixelSize? = nil, resolution: Resolution? = nil,
        prompt: String = "", inputs: RemoteInputs
    ) {
        self.id = id
        self.jobID = jobID
        self.mode = mode
        self.model = model
        self.createdAt = createdAt
        self.isLiked = isLiked
        self.outputURL = outputURL
        self.duration = duration
        self.pixelSize = pixelSize
        self.resolution = resolution
        self.prompt = prompt
        self.inputs = inputs
    }

    /// The inputs as a job that reuses the uploaded media. A remote file can't be trimmed, so the whole source
    /// is selected. Without the source's probed length and frame size, the output's stand in. A generation made
    /// without a source video keeps the output's length.
    public func spec(sourceDuration: TimeInterval? = nil, sourceSize: PixelSize? = nil) -> JobSpec {
        let length = max(0, sourceDuration ?? duration ?? 0)
        let size = sourceSize ?? pixelSize ?? PixelSize(width: 0, height: 0)
        let clip = inputs.video.map {
            SourceClip(fileURL: $0.url, duration: length, pixelSize: size, range: 0...length)
        }
        return JobSpec(
            mode: mode, model: model, source: clip, references: inputs.images.map { LocalImage(fileURL: $0.url) },
            prompt: prompt, resolution: resolution ?? .p720, isDraft: isNativeDraft, remoteInputs: inputs,
            length: clip == nil ? length : nil, aspectRatio: clip == nil ? .auto : nil, draftJobID: draftJobID)
    }
}

extension Job {
    /// A finished generation from the account's history as a library item. Its output is downloaded separately,
    /// and its length and size are read from that file (`JobEngine.importFinished`); the price isn't known, so it
    /// counts as nothing against the spend cap. A native draft keeps its mark, and its finalize window counts from
    /// the item's `createdAt`, the only time history gives.
    public init(importing item: HistoryItem, owner: String?, importedAt: Date) {
        self.init(
            id: item.jobID, spec: item.spec(), providerKind: .account, owner: owner,
            cost: .credits(0, isEstimate: true), createdAt: item.createdAt)
        state = .done
        progress = 1
        inputs = item.inputs
        remote = RemoteJob(requestID: item.id)
        remote?.isNativeDraft = item.isNativeDraft
        chargedAt = item.createdAt
        finishedAt = item.createdAt
        self.importedAt = importedAt
    }
}

/// A finished image generation from the account's history, in the app's terms. Unlike a video it never becomes a
/// job: the library shows it as an image, and downloads its file only when opened, referenced or compared.
public struct HistoryImageItem: Sendable, Hashable, Identifiable {
    /// The provider's generation ID.
    public var id: String
    /// The library row this becomes; kept across reloads of the history.
    public var jobID: UUID
    public var prompt: String
    /// The server's model ID, as the history reports it; the app runs no image models by catalog.
    public var model: String
    public var createdAt: Date
    /// Liked on the provider's side; the library's star for the item.
    public var isLiked: Bool
    public var outputURL: URL
    /// The output's frame size as the provider states it; `nil` when it didn't say.
    public var pixelSize: PixelSize?

    public init(
        id: String, jobID: UUID = UUID(), prompt: String = "", model: String, createdAt: Date,
        isLiked: Bool = false, outputURL: URL, pixelSize: PixelSize? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.prompt = prompt
        self.model = model
        self.createdAt = createdAt
        self.isLiked = isLiked
        self.outputURL = outputURL
        self.pixelSize = pixelSize
    }

    /// "16:9"; `nil` when the provider didn't state the size.
    public var aspectRatio: String? {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let divisor = [pixelSize.width, pixelSize.height].reduce(0) { Self.gcd($0, $1) }
        guard divisor > 0 else { return nil }
        return "\(pixelSize.width / divisor):\(pixelSize.height / divisor)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a
        var b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
