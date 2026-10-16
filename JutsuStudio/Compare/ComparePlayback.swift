import AVFoundation
import Observation
import Presentation

/// One player per track on one clock: the first result leads, the others follow it through `CompareClock`.
/// A source follows from the start of its range; the clock stops at the shortest result.
@MainActor
@Observable
final class ComparePlayback {
    private(set) var players: [CompareTrack.ID: AVPlayer] = [:]
    private(set) var isPlaying = false
    /// Lead time in seconds.
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private struct Follower {
        let id: CompareTrack.ID
        let player: AVPlayer
        let clock: CompareClock
    }

    @ObservationIgnored private var lead: AVPlayer?
    @ObservationIgnored private var leadID: CompareTrack.ID?
    @ObservationIgnored private var followers: [Follower] = []
    @ObservationIgnored private var results: [AVPlayer] = []
    @ObservationIgnored private var seeking: Set<CompareTrack.ID> = []
    @ObservationIgnored private var items: [ScopedPlayerItem] = []
    @ObservationIgnored private var audibleID: CompareTrack.ID?

    func load(_ tracks: [CompareTrack]) {
        pause()
        time = 0
        duration = 0
        seeking = []
        followers = []
        results = []
        items = []
        lead = nil
        leadID = tracks.first { !$0.isSource }?.id ?? tracks.first?.id
        var players: [CompareTrack.ID: AVPlayer] = [:]
        for track in tracks {
            let player = AVPlayer()
            let item = ScopedPlayerItem(url: track.clip.url, bookmark: track.clip.bookmark)
            if track.isSource, let end = track.clip.range?.upperBound {
                item.item.forwardPlaybackEndTime = Self.cmTime(end)
            }
            player.replaceCurrentItem(with: item.item)
            items.append(item)
            players[track.id] = player
            if !track.isSource { results.append(player) }
            if track.id == leadID {
                lead = player
            } else {
                let clock = CompareClock(sourceRange: track.isSource ? track.clip.range : nil)
                followers.append(Follower(id: track.id, player: player, clock: clock))
            }
        }
        self.players = players
        applyAudible()
        for follower in followers { seek(follower, to: follower.clock.sourceTime(atResult: 0)) }
    }

    /// Only this track is heard; `nil` hears the lead.
    func setAudible(_ id: CompareTrack.ID?) {
        audibleID = id
        applyAudible()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let lead else { return }
        if duration > 0, time >= duration - 0.05 { seek(to: 0) }
        for follower in followers { seek(follower, to: follower.clock.sourceTime(atResult: time)) }
        lead.play()
        for follower in followers { follower.player.play() }
        isPlaying = true
    }

    func pause() {
        let now = lead?.currentTime().seconds ?? .nan
        if isPlaying, now.isFinite { time = duration > 0 ? min(now, duration) : now }
        lead?.pause()
        for follower in followers { follower.player.pause() }
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        time = max(0, seconds)
        lead?.seek(to: Self.cmTime(time), toleranceBefore: .zero, toleranceAfter: .zero)
        for follower in followers { seek(follower, to: follower.clock.sourceTime(atResult: time)) }
    }

    /// Called a few times a second: follows the lead's clock and pulls the others back when they drift.
    func tick() {
        duration = CompareTimeline.duration(of: results.map { $0.currentItem?.duration.seconds })
        guard isPlaying, let lead else { return }
        time = lead.currentTime().seconds
        // `actionAtItemEnd` paused the lead at its end, or a shorter result ended.
        if lead.rate == 0 || (duration > 0 && time >= duration) {
            pause()
            return
        }
        for follower in followers where !seeking.contains(follower.id) {
            if let target = follower.clock.correction(
                resultTime: time, sourceTime: follower.player.currentTime().seconds)
            {
                seek(follower, to: target)
            }
        }
    }

    private func applyAudible() {
        let audible = audibleID.flatMap { players[$0] == nil ? nil : $0 } ?? leadID
        for (id, player) in players { player.isMuted = id != audible }
    }

    private func seek(_ follower: Follower, to seconds: TimeInterval) {
        let id = follower.id
        seeking.insert(id)
        follower.player.seek(to: Self.cmTime(seconds), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.seeking.remove(id) }
        }
    }

    private static func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
