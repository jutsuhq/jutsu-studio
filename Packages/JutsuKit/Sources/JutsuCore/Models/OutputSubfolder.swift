import Foundation

/// The folders inside the output folder, one per kind of result, so each kind stays apart from the others and a new
/// kind gets a folder of its own next to them.
public enum OutputSubfolder: String, CaseIterable, Sendable {
    /// Finished jobs: generations, finals and operations.
    case videos = "Videos"
    /// Images made with Generate… and character sheets (`SavedImage`).
    case images = "Images"

    /// This folder inside `outputFolder`.
    public func url(in outputFolder: URL) -> URL {
        outputFolder.appending(path: rawValue, directoryHint: .isDirectory)
    }
}
