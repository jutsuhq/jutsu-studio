import AVFoundation
import SwiftUI

/// A muted video that loops from the start while shown, filling its frame: hover previews of styles and clips.
/// It never takes the mouse, so the tile under it keeps its clicks and hover.
struct LoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PassiveVideoView {
        let view = PassiveVideoView()
        context.coordinator.play(url, in: view)
        return view
    }

    func updateNSView(_ view: PassiveVideoView, context: Context) {
        context.coordinator.play(url, in: view)
    }

    static func dismantleNSView(_ view: PassiveVideoView, coordinator: Coordinator) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
        coordinator.looper = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var looper: AVPlayerLooper?
        private var url: URL?

        func play(_ url: URL, in view: PassiveVideoView) {
            guard url != self.url else { return }
            self.url = url
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            view.playerLayer.player = player
            player.play()
        }
    }

    /// An `AVPlayerLayer` host that is invisible to hit testing; `AVPlayerView` would take clicks and hover.
    final class PassiveVideoView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
