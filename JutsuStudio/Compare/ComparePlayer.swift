import AVFoundation
import AVKit
import MediaKit
import Presentation
import SwiftUI

/// Any number of videos on one clock, each labelled with its chips: side by side, or, for two, layered with the
/// second right of a draggable divider. Knows nothing of the Library, so other pages can lay out their own tracks.
struct ComparePlayer: View {
    let tracks: [CompareTrack]
    var layout: CompareLayout = .sideBySide
    /// Width over height of the videos; each pane keeps it and centers in the space it gets.
    var aspect: CGFloat = 16 / 9
    /// Off when the page takes the arrow keys for something else, e.g. swapping sides.
    var nudgesWithArrows = true

    @State private var playback = ComparePlayback()
    @State private var divider = CompareDivider()

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            surface
            transport
        }
        // A set, so reordering the tracks moves the panes without reloading the players.
        .task(id: Set(tracks)) {
            playback.load(tracks)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                playback.tick()
            }
        }
        .onChange(of: audibleTrack, initial: true) { _, track in playback.setAudible(track) }
        .onDisappear { playback.pause() }
    }

    /// The leftmost result is heard; several soundtracks at once would echo.
    private var audibleTrack: CompareTrack.ID? {
        tracks.first { !$0.isSource }?.id
    }

    @ViewBuilder
    private var surface: some View {
        if layout == .divider, tracks.count == 2 {
            dividerSurface(base: tracks[0], over: tracks[1])
        } else {
            grid
        }
    }

    // MARK: Side by side

    private var grid: some View {
        let columns = CompareLayout.columns(forTrackCount: tracks.count)
        let rows = stride(from: 0, to: tracks.count, by: columns).map {
            Array(tracks[$0..<min($0 + columns, tracks.count)])
        }
        return VStack(spacing: Theme.Spacing.small) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: Theme.Spacing.small) {
                    ForEach(rows[row]) { track in
                        video(track)
                            .allowsHitTesting(false)
                            .overlay(alignment: .topLeading) {
                                TrackLabels(labels: track.labels).padding(Theme.Spacing.small)
                            }
                            .aspectRatio(aspect, contentMode: .fit)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityElement()
                            .accessibilityLabel(track.labels.joined(separator: ", "))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Divider

    private func dividerSurface(base: CompareTrack, over: CompareTrack) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let dividerX = width * divider.position
            ZStack(alignment: .topLeading) {
                Group {
                    video(base)
                    video(over)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: max(0, width - dividerX))
                        }
                }
                .allowsHitTesting(false)
                // Takes the drag in SwiftUI; the AppKit player views underneath would swallow the mouse.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in divider.drag(to: value.location.x, width: width) }
                    )
                DividerLine()
                    .frame(width: 28)
                    .offset(x: dividerX - 14)
                HStack(alignment: .top) {
                    TrackLabels(labels: base.labels)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TrackLabels(labels: over.labels)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(Theme.Spacing.small)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(dividerControls(base: base, over: over))
    }

    /// Arrow keys and VoiceOver move the divider.
    private func dividerControls(base: CompareTrack, over: CompareTrack) -> some ViewModifier {
        DividerControls(
            divider: $divider, nudgesWithArrows: nudgesWithArrows,
            hint: String(localized: "\(Self.labels(base)) on the left, \(Self.labels(over)) on the right")
        )
    }

    private static func labels(_ track: CompareTrack) -> String {
        track.labels.joined(separator: ", ")
    }

    @ViewBuilder
    private func video(_ track: CompareTrack) -> some View {
        if let player = playback.players[track.id] {
            PlayerSurface(player: player)
        } else {
            Color.black
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button(
                playback.isPlaying ? "Pause" : "Play",
                systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
            ) {
                playback.togglePlay()
            }
            .buttonStyle(.iconAction)
            .keyboardShortcut(.space, modifiers: [])
            Slider(
                value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }),
                in: 0...max(playback.duration, 0.1)
            )
            .labelsHidden()
            .accessibilityLabel("Playback position")
            .accessibilityValue(LibraryFormat.timecode(playback.time))
            Text(LibraryFormat.timecode(playback.time))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
    }
}

private struct DividerControls: ViewModifier {
    @Binding var divider: CompareDivider
    let nudgesWithArrows: Bool
    let hint: String

    func body(content: Content) -> some View {
        content
            .focusable(nudgesWithArrows)
            .onMoveCommand { direction in
                guard nudgesWithArrows else { return }
                switch direction {
                case .left: divider.nudge(by: -1)
                case .right: divider.nudge(by: 1)
                default: break
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Compare divider")
            .accessibilityValue(divider.percentText)
            .accessibilityHint(hint)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: divider.nudge(by: 1)
                case .decrement: divider.nudge(by: -1)
                @unknown default: break
                }
            }
    }
}

/// A track's chips on its video frame.
private struct TrackLabels: View {
    let labels: [String]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(labels, id: \.self) { MediaTag(text: $0) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The divider in the signature gradient with a neutral grip; the gradient marks the effect, not a control.
private struct DividerLine: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(gradient: Theme.signature, startPoint: .top, endPoint: .bottom))
                .frame(width: 2)
                .shadow(color: Theme.signatureFuchsia.opacity(0.6), radius: 6)
            Image(systemName: "chevron.left.chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 24, height: 24)
                .background(Theme.scrim, in: Circle())
                .overlay { Circle().strokeBorder(Theme.glassStroke, lineWidth: 0.5) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A bare video layer, for players that draw their own controls (compare, batch comparison).
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
