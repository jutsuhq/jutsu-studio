import Presentation
import SwiftUI

/// An empty, dashed drop zone that opens a file picker; files can also be dropped on its section (`.drop`).
struct DropButton: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.1), in: Circle())
                    .padding(.bottom, 2)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .dropZone()
    }
}

/// The source video: its name and the selected ranges, or a drop zone.
struct SourceSection: View {
    @Binding var form: CreateForm
    let onImport: (URL) -> Void
    let onPick: () -> Void
    /// The link being downloaded for this section, if any.
    var linkDownload: LinkDownload?
    let onPasteLink: () -> Void
    let onCancelLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                SectionLabel(
                    title: "Source video",
                    detail: form.selectedModel.makesClipsWithoutSource
                        ? String(localized: "Optional · 4–30 s") : String(localized: "4–30 s"))
                PasteLinkButton(action: onPasteLink)
                    .disabled(linkDownload != nil)
            }
            if let linkDownload {
                LinkDownloadRow(download: linkDownload, onCancel: onCancelLink)
            }
            if let source = form.source {
                HStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(form.sourceSummary)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 0)
                    Button {
                        form.setSource(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .hoverHint("Remove video")
                    .accessibilityLabel("Remove video")
                }
                .padding(Theme.Spacing.medium)
                .well()
                if let notice = form.upscaleNotice {
                    UpscaleNoticeView(notice: notice, isOn: $form.allowsUpscale)
                }
            } else {
                DropButton(
                    title: String(localized: "Add a video"),
                    detail: form.selectedModel.makesClipsWithoutSource
                        ? String(localized: "Or describe the clip in the prompt")
                        : String(localized: "Any format · trimmed to 4–30 s"),
                    systemImage: "video"
                ) {
                    onPick()
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onImport(url)
            return true
        }
    }
}

private struct UpscaleNoticeView: View {
    let notice: Notice
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.callout.bold())
                    .foregroundStyle(Theme.text)
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Toggle("Upscale before upload", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
        }
        .padding(Theme.Spacing.medium)
        .well()
    }
}
