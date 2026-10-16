import Foundation
import JobEngine
import JutsuCore
import Presentation
import SwiftUI

extension AppEnvironment {
    /// Downloads a pasted link into `links/`, which Clear Cache empties like the other downloaded inputs.
    func downloadLink(
        _ link: URL, expected: MediaLink.Kind?, progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> DownloadedMedia {
        try await MediaLinkDownloader().download(
            link, into: layout.linkedMediaFolder, expected: expected, progress: progress)
    }
}

/// "Paste URL…" next to a section's title.
struct PasteLinkButton: View {
    let action: () -> Void

    var body: some View {
        Button("Paste URL…", systemImage: "link", action: action)
            .buttonStyle(.iconAction)
            .controlSize(.small)
            .hoverHint("Download from a link")
    }
}

/// A link being downloaded: its host, progress and Cancel.
struct LinkDownloadRow: View {
    let download: LinkDownload
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(download.text)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = download.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .tint(Theme.accent)
        .padding(Theme.Spacing.medium)
        .well()
    }
}
