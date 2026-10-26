import AppKit
import JutsuCore
import MediaKit
import Presentation
import SwiftUI

// Paste URL… and ⌘V on the Create screen: the links they download and the files the clipboard holds.
extension CreateView {
    /// Opens the Paste URL… field, filled with the clipboard's link if it holds one.
    func askForLink(_ kind: MediaLink.Kind) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        linkText = (try? MediaLink.parse(text))?.absoluteString ?? ""
        linkEntry = kind
    }

    func downloadTypedLink(as kind: MediaLink.Kind) {
        do {
            downloadLink(try MediaLink.parse(linkText), expected: kind)
        } catch {
            alert = UserMessage(error)
        }
    }

    /// Downloads `link`, then takes the file like a dropped one: a video becomes the source, an image a reference.
    /// The file remembers the link, so a job that sends it whole can pass the link instead of uploading it.
    private func downloadLink(_ link: URL, expected: MediaLink.Kind?) {
        linkTask?.cancel()
        let download = LinkDownload(link: link, expected: expected)
        linkDownload = download
        linkTask = Task {
            defer {
                if linkDownload?.id == download.id { linkDownload = nil }
            }
            do {
                let throttle = ProgressThrottle()
                let media = try await environment.downloadLink(link, expected: expected) { fraction in
                    guard throttle.admits(fraction) else { return }
                    Task { @MainActor in showLinkProgress(fraction, of: download.id) }
                }
                try Task.checkCancellation()
                switch media.kind {
                case .video:
                    importSource(media.fileURL, origin: media.origin)
                case .image:
                    let image = LocalImage(
                        fileURL: media.fileURL, bookmark: AppEnvironment.bookmark(for: media.fileURL),
                        remoteOrigin: media.origin)
                    alert = navigation.createDraft.addOpenedReferences([image]) ?? alert
                }
            } catch is CancellationError {
                return
            } catch {
                alert = UserMessage(error)
            }
        }
    }

    /// Only reports that change the whole percent get here (`ProgressThrottle`); a late one of an earlier link is
    /// dropped.
    private func showLinkProgress(_ fraction: Double?, of id: UUID) {
        guard var current = linkDownload, current.id == id else { return }
        current.fraction = fraction
        linkDownload = current
    }

    func cancelLinkDownload() {
        linkTask?.cancel()
        linkTask = nil
        linkDownload = nil
    }

    /// Takes the clipboard the way opened files are taken (bookmarks, the source probe, the reference limit);
    /// image data, such as a screenshot, is saved to a file first, and an `https:` link is downloaded first.
    func paste() {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let links = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let input = PastedInput(
            fileURLs: files as? [URL] ?? [], hasImage: NSImage.canInit(with: pasteboard), links: links,
            text: pasteboard.string(forType: .string))
        switch input {
        case .link(let link)?:
            downloadLink(link, expected: nil)
        case .files(let urls)?:
            navigation.open(urls)
        case .image?:
            do {
                navigation.open([try environment.savePastedImage(from: pasteboard)])
            } catch {
                alert = UserMessage(
                    title: String(localized: "Can't paste the image"), message: error.localizedDescription)
            }
        case nil:
            NSSound.beep()
        }
    }
}
