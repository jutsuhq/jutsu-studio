import AppKit
import JobEngine
import JutsuCore
import MediaKit
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Library")

/// Saves a result's inputs back to the Mac: a copy of the file on this Mac while it is there, else the one
/// Higgsfield keeps, downloaded.
@MainActor
enum InputExport {
    /// Asks where to save, saves, and shows the saved files in Finder. One file gets a save panel with its name;
    /// several get a folder. Returns what to tell the user when a file couldn't be saved.
    static func run(_ files: [InputFile], base: String) async -> UserMessage? {
        guard let targets = choose(files, base: base) else { return nil }
        var saved: [URL] = []
        var failed: [String] = []
        for (file, target) in targets {
            do {
                try await save(file, to: target)
                saved.append(target)
            } catch {
                logger.error("Can't save an input: \(String(describing: error), privacy: .private)")
                failed.append(file.title)
            }
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        guard !failed.isEmpty else { return nil }
        return UserMessage(
            title: String(
                localized: "Can't save \(ListFormatter.localizedString(byJoining: failed).lowercased(with: nil))"),
            message: String(
                localized:
                    "It is no longer on this Mac, and the download from Higgsfield failed. Try again in a moment."))
    }

    private static func choose(_ files: [InputFile], base: String) -> [(InputFile, URL)]? {
        if files.count == 1, let file = files.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.fileName(base: base)
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return [(file, url)]
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Save Here")
        panel.message = String(localized: "Choose a folder for the source video and reference images.")
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        var taken = Set<URL>()
        return files.map { file in
            let url = folder.appending(path: file.fileName(base: base)).unusedFileURL {
                taken.contains($0) || FileManager.default.fileExists(atPath: $0.path)
            }
            taken.insert(url)
            return (file, url)
        }
    }

    /// The save panel already asked before replacing a file, so one at `target` is replaced, but only once the new
    /// one is ready: a copy or download that fails leaves it as it was.
    private static func save(_ file: InputFile, to target: URL) async throws {
        // In the temporary folder: a save panel grants only the file it named, not a partial file beside it.
        let partial = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: partial) }
        if !(file.local.map { copy($0, to: partial) } ?? false) {
            guard let remote = file.remote else { throw CocoaError(.fileNoSuchFile) }
            try? FileManager.default.removeItem(at: partial)
            try await URLSessionDownloader().download(remote, to: partial)
        }
        try FileReplacement.move(partial, to: target)
    }

    private static func copy(_ local: LocalImage, to target: URL) -> Bool {
        withScopedAccess(to: local.fileURL, bookmark: local.bookmark) { access in
            (try? FileManager.default.copyItem(at: access.url, to: target)) != nil
        }
    }
}
