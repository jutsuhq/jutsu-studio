import AVFoundation
import Combine
import JutsuCore
import Presentation
import SwiftUI

/// The result's first frame inside the outline of the canvas Reframe would make; the area around the frame is what
/// Higgsfield fills in.
struct ReframePreview: View {
    let url: URL?
    let canvas: ReframeCanvas?
    /// Set to the first frame's size once it loads.
    @Binding var frameSize: PixelSize?

    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Group {
                if let canvas {
                    canvasView(canvas)
                } else {
                    Rectangle().fill(Theme.well)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .task(id: url) {
            guard let url else { return }
            image = await ThumbnailCache.shared.image(for: url)
            if let image { frameSize = PixelSize(width: image.width, height: image.height) }
        }
    }

    private func canvasView(_ canvas: ReframeCanvas) -> some View {
        Theme.well
            .overlay {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    frame
                        .frame(width: width * canvas.frameWidth, height: height * canvas.frameHeight)
                        .offset(x: width * canvas.frameX, y: height * canvas.frameY)
                }
            }
            .overlay {
                Rectangle()
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .aspectRatio(canvas.widthOverHeight, contentMode: .fit)
            .accessibilityElement()
            .accessibilityLabel(caption)
    }

    @ViewBuilder private var frame: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable()
        } else {
            Rectangle().fill(Theme.card)
        }
    }

    private var caption: String {
        guard let canvas else { return String(localized: "Reading the result's size…") }
        return canvas.isUnchanged
            ? String(localized: "The result already has this shape; pick another one.")
            : String(localized: "The dashed outline is the new canvas. Higgsfield fills in the area around the result.")
    }
}

/// The account's voices, each with a sample to play; one is picked for Change Voice. Playback stops when the sheet
/// closes.
struct VoicePicker: View {
    @Binding var selection: VoiceChoice?

    @Environment(AppEnvironment.self) private var environment
    @State private var voices: [AccountVoice]?
    @State private var failed = false
    /// Made when the first sample plays: a default value here would build a new player every time the parent rebuilds
    /// this view.
    @State private var player: AVPlayer?
    /// The voice whose sample is playing, or loading.
    @State private var playing: AccountVoice.ID?
    /// The sample is still downloading: the first one takes a moment, and a silent button read as a dead click.
    @State private var isLoading = false

    var body: some View {
        Group {
            if let voices, !voices.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(voices) { row($0) }
                    }
                }
                .frame(height: 220)
            } else if voices != nil {
                notice(String(localized: "Higgsfield lists no voices for this account."))
            } else if failed {
                notice(String(localized: "Can't load the voices. Close this and try again."))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task { await load() }
        .onDisappear { stop() }
        .onReceive(
            NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
                .receive(on: DispatchQueue.main)
        ) { notification in
            if let item = notification.object as? AVPlayerItem, item === player?.currentItem { playing = nil }
        }
        .onReceive(statusChanges) { status in
            if status == .playing { isLoading = false }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)
                .receive(on: DispatchQueue.main)
        ) { notification in
            if let item = notification.object as? AVPlayerItem, item === player?.currentItem { stop() }
        }
    }

    private func row(_ voice: AccountVoice) -> some View {
        let isSelected = selection == voice.choice
        return HStack(spacing: Theme.Spacing.small) {
            Button {
                selection = voice.choice
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
                    Text(voice.choice.name)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(voice.kindLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let url = voice.previewURL {
                let isPlaying = playing == voice.id
                Button {
                    isPlaying ? stop() : play(url, of: voice)
                } label: {
                    if isPlaying && isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    }
                }
                .buttonStyle(.iconAction)
                .hoverHint(
                    isPlaying
                        ? (isLoading ? String(localized: "Loading the sample…") : String(localized: "Stop the sample"))
                        : String(localized: "Play a sample")
                )
                .accessibilityLabel(
                    isPlaying ? String(localized: "Stop the sample") : String(localized: "Play a sample"))
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
    }

    private func load() async {
        guard voices == nil else { return }
        if let list = await environment.voices() {
            voices = list
        } else {
            failed = true
        }
    }

    /// The player's `timeControlStatus`; nothing before the first sample.
    private var statusChanges: AnyPublisher<AVPlayer.TimeControlStatus, Never> {
        guard let player else { return Empty().eraseToAnyPublisher() }
        return player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    private func play(_ url: URL, of voice: AccountVoice) {
        let player = self.player ?? AVPlayer()
        self.player = player
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        playing = voice.id
        isLoading = true
    }

    private func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playing = nil
        isLoading = false
    }
}
