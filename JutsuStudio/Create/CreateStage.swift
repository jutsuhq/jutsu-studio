import AVKit
import JutsuCore
import MediaKit
import Presentation
import SwiftUI
import UniformTypeIdentifiers

/// The right side of Create: an empty drop target (the Motion Library for Motion and Swap on an account), or the
/// preview with its facts and the trim strip.
struct CreateStage: View {
    @Binding var form: CreateForm
    /// The active connection's kind, which decides the seconds billed; `nil` while disconnected.
    let connection: ProviderKind?
    /// `nil` when the connection has no library.
    let library: MotionLibraryModel?
    let downloadingClip: String?
    let onImportSource: (URL) -> Void
    let onPickSource: () -> Void
    let onPickClip: (MotionPreset) -> Void

    @State private var player: AVPlayer?
    @State private var playerItem: ScopedPlayerItem?

    var body: some View {
        Group {
            if let source = form.source {
                VStack(spacing: Theme.Spacing.medium) {
                    preview(source)
                    TrimStripView(form: $form, connection: connection) { time in
                        seek(to: time)
                    }
                    .padding(Theme.Spacing.large)
                    .card()
                }
            } else if let library, form.mode != .restyle {
                MotionLibraryBrowser(
                    model: library, downloadingID: downloadingClip, onPick: onPickClip, onPickFile: onPickSource
                )
                // A new connection brings a new model; its loading tasks must start over.
                .id(ObjectIdentifier(library))
            } else {
                emptyStage
            }
        }
        .onChange(of: form.source?.fileURL, initial: true) {
            let item = form.source.map { ScopedPlayerItem(url: $0.fileURL, bookmark: $0.bookmark) }
            player = item.map { AVPlayer(playerItem: $0.item) }
            playerItem = item
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onImportSource(url)
            return true
        }
    }

    /// The facts sit in a bar above the picture, so nothing covers the clip.
    private func preview(_ source: SourceVideo) -> some View {
        VStack(spacing: 0) {
            infoBar(source)
            ZStack {
                Theme.background
                if let player {
                    PlayerView(player: player)
                }
            }
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }

    /// One line: name, size and format, what will happen to the file, and the remove button. On a narrow stage
    /// the notes go on lines of their own below, where they aren't cut short.
    private func infoBar(_ source: SourceVideo) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.small) {
                facts(source)
                pills
                removeButton
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Theme.Spacing.small) {
                    facts(source)
                    removeButton
                }
                pills
            }
        }
        .padding(.leading, Theme.Spacing.medium)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    @ViewBuilder private func facts(_ source: SourceVideo) -> some View {
        Text(source.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.middle)
        Text("\(source.sizeText) · \(source.fileText)")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
            .layoutPriority(1)
        Spacer(minLength: Theme.Spacing.small)
    }

    private var pills: some View {
        ForEach(form.stagePills, id: \.self) { text in
            Pill(text: text, dot: Theme.warning)
                .layoutPriority(1)
        }
    }

    /// Clears the source where it is shown; with a library, that returns to the clips.
    private var removeButton: some View {
        let backToLibrary = library != nil && form.mode != .restyle
        return Button {
            form.setSource(nil)
        } label: {
            Label(backToLibrary ? "Back to Clips" : "Remove Video", systemImage: "xmark")
        }
        .buttonStyle(.iconAction)
        .hoverHint(backToLibrary ? "Remove this video and pick another clip" : "Remove this video")
    }

    private var emptyStage: some View {
        Button {
            onPickSource()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)
                Text("Drop a video")
                    .font(.display(34))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.text)
                Text(
                    """
                    MOV, MP4, HEVC, ProRes — converted and trimmed for you. \
                    The clip needs 4 to 30 seconds of motion.
                    """
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .well(radius: Theme.Radius.card)
    }

    private func seek(to time: TimeInterval) {
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// `AVPlayerView` with inline controls; SwiftUI's `VideoPlayer` has no trim-friendly scrubbing.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
