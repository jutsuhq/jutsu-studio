import AVFoundation
import AVKit
import MediaKit
import Presentation
import SwiftUI

/// Plays a local file; a source clip starts at its range and stops at its end.
struct LibraryPlayer: View {
    let clip: PlaybackClip
    var aspect: CGFloat = 16 / 9
    /// Made on first load: a default value here would build a new player every time the parent rebuilds this view.
    @State private var player: AVPlayer?
    @State private var item: ScopedPlayerItem?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: clip, initial: true) { load() }
            .onDisappear { player?.pause() }
    }

    private func load() {
        let player = self.player ?? AVPlayer()
        self.player = player
        player.pause()
        let item = ScopedPlayerItem(url: clip.url, bookmark: clip.bookmark)
        if let range = clip.range {
            item.item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600)
        }
        player.replaceCurrentItem(with: item.item)
        self.item = item
        if let range = clip.range {
            player.seek(
                to: CMTime(seconds: range.lowerBound, preferredTimescale: 600), toleranceBefore: .zero,
                toleranceAfter: .zero)
        }
    }
}
