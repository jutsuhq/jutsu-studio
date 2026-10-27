import Foundation
import JutsuCore

/// The speech models the app downloads itself, as Settings › Subtitles shows them: Parakeet Ultra, downloaded into the
/// app's own folder only when the person asks, and removed on request. The folders of earlier revisions count in its
/// size until the current revision is downloaded or removed, which deletes them.
@MainActor
@Observable
public final class SpeechModels {
    public enum State: Sendable, Hashable {
        case notDownloaded
        /// 0…1.
        case downloading(Double)
        case ready
    }

    public private(set) var state: State
    /// What the model's folders take on disk, earlier revisions' included.
    public private(set) var size: Int64 = 0
    /// What went wrong with the last download or removal, until it is shown.
    public var failure: UserMessage?

    /// Parakeet Ultra's folder: one per revision, so another revision never mixes with it.
    public let folder: URL
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let downloader: any SpeechModelDownloading
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Called when the model comes or goes, so the Subtitles sheet reads its languages again.
    @ObservationIgnored public var onChange: @MainActor () -> Void = {}

    /// - Parameter root: the folder the app keeps its models in.
    public init(root: URL, downloader: any SpeechModelDownloading) {
        folder = root.appending(path: "\(Self.prefix)\(ParakeetUltra.revision.prefix(8))", directoryHint: .isDirectory)
        self.root = root
        self.downloader = downloader
        state = downloader.isComplete(ParakeetUltra.manifest, in: folder) ? .ready : .notDownloaded
        size = measured()
    }

    static let prefix = "parakeet-ultra-"

    public var isDownloading: Bool {
        if case .downloading = state { true } else { false }
    }

    /// Downloads what is missing; a download stopped before goes on from where it was.
    public func download() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        let (downloader, folder) = (downloader, folder)
        let throttle = ProgressThrottle()
        task = Task { [weak self] in
            let work = Task.detached(priority: .utility) {
                try await downloader.download(ParakeetUltra.manifest, into: folder) { fraction in
                    guard throttle.admits(fraction) else { return }
                    Task { @MainActor in self?.progress(fraction) }
                }
            }
            do {
                try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
            } catch {
                if !(error is CancellationError), !Task.isCancelled {
                    self?.failure = UserMessage(
                        title: SubtitleText.downloadFailedTitle, message: error.localizedDescription)
                }
            }
            self?.settle()
        }
    }

    /// Stops a download; what came down so far stays for the next one.
    public func cancel() {
        task?.cancel()
    }

    /// Deletes the model's folder, and those of earlier revisions.
    public func remove() {
        guard task == nil else { return }
        do {
            try downloader.remove(folder)
            try removeEarlierRevisions()
        } catch {
            failure = UserMessage(title: SubtitleText.removeFailedTitle, message: error.localizedDescription)
        }
        settle()
    }

    /// Waits for a download in flight.
    public func finish() async {
        await task?.value
    }

    private func progress(_ fraction: Double) {
        if isDownloading { state = .downloading(fraction) }
    }

    private func settle() {
        task = nil
        state = downloader.isComplete(ParakeetUltra.manifest, in: folder) ? .ready : .notDownloaded
        if state == .ready {
            do {
                try removeEarlierRevisions()
            } catch {
                failure = UserMessage(title: SubtitleText.removeFailedTitle, message: error.localizedDescription)
            }
        }
        size = measured()
        onChange()
    }

    /// The folders other revisions of the model were downloaded into.
    private var earlierRevisions: [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter {
            $0.lastPathComponent.hasPrefix(Self.prefix) && $0.lastPathComponent != folder.lastPathComponent
        }
    }

    private func removeEarlierRevisions() throws {
        for old in earlierRevisions { try downloader.remove(old) }
    }

    private func measured() -> Int64 {
        ([folder] + earlierRevisions).reduce(0) { $0 + downloader.size(of: $1) }
    }
}
