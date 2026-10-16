import AppKit
import JutsuCore
import Persistence
import Presentation
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Library")

/// "Edit in…" and "Import as New Version…": the round trip through another app (`OutsideEdit`). The other app gets a
/// working copy in the temporary folder, never the library's file; what comes back is copied into the output folder
/// and becomes a new version of the same material.
extension AppEnvironment {
    /// Working copies for other apps, one folder per copy (`OutsideEdit.workingCopy`). Next to the store rather than
    /// in the temporary folder, which the system empties: an edit saved in place must still be there to import.
    /// note: copies are never cleaned up; a "remove imported copies" pass is the upgrade path if they pile up.
    var outsideEditRoot: URL {
        layout.root.appending(path: "Edit In", directoryHint: .isDirectory)
    }

    /// Asks for an app, then opens a working copy of the material's current version in it.
    func editInOtherApp(_ material: Material) -> UserMessage? {
        guard let file = material.current.fileURL else { return nil }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Edit")
        panel.message = String(
            localized:
                "Choose the app to edit a copy in. The original stays as it is; bring the edit back with Import as New Version or by dropping it on the card."
        )
        guard panel.runModal() == .OK, let app = panel.url else { return nil }
        do {
            let copy = try OutsideEdit.workingCopy(of: file, version: material.reference, in: outsideEditRoot)
            NSWorkspace.shared.open([copy], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return nil
        } catch {
            logger.error("Can't make a copy to edit: \(String(describing: error), privacy: .private)")
            return UserMessage(
                title: String(localized: "Can't open a copy to edit"), message: error.localizedDescription)
        }
    }

    /// Asks for the edited file, then imports it like a drop.
    func pickEditedVersion(of material: Material) async -> UserMessage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [material.kind == .image ? .image : .movie]
        panel.directoryURL = outsideEditRoot
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose the edited file. It is copied into the library as a new version.")
        guard panel.runModal() == .OK, let file = panel.url else { return nil }
        return await importEditedVersion(file, of: material)
    }

    /// Copies `file` into the output folder and adds it as the material's new version, linked to the version its
    /// working copy was made from (else the current one). The edited file and the earlier versions are untouched.
    func importEditedVersion(_ file: URL, of material: Material) async -> UserMessage? {
        let isAccessing = file.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { file.stopAccessingSecurityScopedResource() }
        }
        let parent = OutsideEdit.parent(of: file, for: material, root: outsideEditRoot)
        let copy: URL
        do {
            copy = try OutsideEdit.copyBack(
                file, into: outputFolder.url(of: material.kind == .image ? .images : .videos))
        } catch {
            return Self.importFailure(error)
        }
        do {
            try await store.addEditedVersion(of: parent, file: copy)
        } catch {
            // Not in the catalog, so taken back: a second try doesn't leave a second copy.
            try? FileManager.default.removeItem(at: copy)
            return Self.importFailure(error)
        }
        await imageLibrary.load()
        return nil
    }

    private static func importFailure(_ error: any Error) -> UserMessage {
        logger.error("Can't import an edited version: \(String(describing: error), privacy: .private)")
        return UserMessage(
            title: String(localized: "Can't import the edited file"), message: error.localizedDescription)
    }
}
