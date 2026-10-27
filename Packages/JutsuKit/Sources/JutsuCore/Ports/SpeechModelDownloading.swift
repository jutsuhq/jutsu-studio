import Foundation

/// Downloads a model's files (`ModelManifest`) into a folder of the app's own, checks them, and removes them.
public protocol SpeechModelDownloading: Sendable {
    /// Whether every file is in `folder` at its size; reads no content.
    func isComplete(_ manifest: ModelManifest, in folder: URL) -> Bool

    /// Downloads the files that aren't complete yet, each resuming where an earlier download stopped, and checks
    /// each against its hash; a file that doesn't match is deleted and the download fails.
    /// - Parameter progress: 0…1 of the whole model.
    func download(
        _ manifest: ModelManifest, into folder: URL, progress: @escaping @Sendable (Double) -> Void)
        async throws

    /// What `folder` takes on disk, in bytes.
    func size(of folder: URL) -> Int64

    func remove(_ folder: URL) throws
}
