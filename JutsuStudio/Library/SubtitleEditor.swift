import AVFoundation
import AVKit
import JutsuCore
import Persistence
import Presentation
import SwiftUI

/// The player beside the subtitle editor: where playback is, ten times a second, and seeking to a cue.
@MainActor
@Observable
final class SubtitlePlayback {
    let player = AVPlayer()
    private(set) var time: TimeInterval = 0
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private let item: ScopedPlayerItem

    init(file: URL, bookmark: Data?) {
        item = ScopedPlayerItem(url: file, bookmark: bookmark)
        player.replaceCurrentItem(with: item.item)
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.time = time.seconds }
        }
    }

    func seek(to seconds: TimeInterval) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

/// The exact version the editor opened on: its subtitles then, and its file.
struct SubtitleEditorTarget {
    let subtitles: Subtitles
    let reference: MaterialReference
    let file: URL
    let bookmark: Data?
}

/// A version's subtitles beside its video: the cue on screen follows playback, each cue's text can be edited, and a
/// cue can be merged with the next or split in two. Done saves them on the version the editor opened on; when that
/// version's subtitles were made again meanwhile, it asks before replacing them. Cancel leaves them as they were.
struct SubtitleEditorPage: View {
    let target: SubtitleEditorTarget
    let aspect: CGFloat
    let close: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var subtitles: Subtitles
    @State private var playback: SubtitlePlayback
    @State private var message: UserMessage?
    @State private var isConfirmingReplace = false

    init(target: SubtitleEditorTarget, aspect: CGFloat, close: @escaping () -> Void) {
        self.target = target
        self.aspect = aspect
        self.close = close
        _subtitles = State(initialValue: target.subtitles)
        _playback = State(initialValue: SubtitlePlayback(file: target.file, bookmark: target.bookmark))
    }

    private var current: SubtitleCue? { subtitles.cue(at: playback.time) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack(spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SubtitleText.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                    Text(SubtitleText.summary(of: subtitles)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: Theme.Spacing.small)
                Button("Cancel", action: leave)
                    .buttonStyle(.secondaryAction)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: save)
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(alignment: .top, spacing: Theme.Spacing.xLarge) {
                VideoPlayer(player: playback.player) {
                    CueOverlay(text: current?.lines.joined(separator: "\n"))
                }
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                cueList.frame(width: 340)
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.pageTop)
        .padding(.bottom, Theme.Spacing.page)
        .onDisappear { playback.stop() }
        .alert(message?.title ?? "", isPresented: Binding(isPresenting: $message), presenting: message) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
        .confirmationDialog(SubtitleText.changedMeanwhileTitle, isPresented: $isConfirmingReplace) {
            Button("Replace with Mine", role: .destructive) { write() }
            Button("Keep the New Ones", action: leave)
        } message: {
            Text(SubtitleText.changedMeanwhileMessage)
        }
    }

    private var cueList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(subtitles.cues) { cue in
                    CueRow(
                        cue: cue, isCurrent: cue.id == current?.id,
                        text: Binding(get: { cue.text }, set: { subtitles.setText($0, of: cue.id) }),
                        canMerge: subtitles.canMerge(cue.id), canSplit: subtitles.canSplit(cue.id),
                        seek: { playback.seek(to: cue.start) },
                        merge: { subtitles.mergeWithNext(cue.id) }, split: { subtitles.split(cue.id) }
                    )
                    .id(cue.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: current?.id) { _, id in
                guard let id, playback.player.timeControlStatus == .playing else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Saves onto the version the editor opened on, unless its subtitles changed since: then the person decides.
    private func save() {
        let reference = target.reference
        Task {
            let material = try? await environment.store.material(id: reference.materialID)
            let version = material?.versions.first { $0.id == reference.versionID }
            switch SubtitleSave.decide(opened: target.subtitles, stored: version.map(\.subtitles)) {
            case .save: write()
            case .changedMeanwhile: isConfirmingReplace = true
            case .versionGone:
                message = UserMessage(title: SubtitleText.notSavedTitle, message: SubtitleText.versionGoneMessage)
            }
        }
    }

    private func write() {
        let (subtitles, reference) = (subtitles, target.reference)
        Task {
            do {
                try await environment.store.setSubtitles(subtitles, for: reference)
                leave()
            } catch {
                message = UserMessage(title: SubtitleText.notSavedTitle, message: error.localizedDescription)
            }
        }
    }

    private func leave() {
        playback.stop()
        close()
    }
}

/// The cue on screen over the video, as a burned-in subtitle looks: white, semibold, with a soft shadow.
private struct CueOverlay: View {
    let text: String?

    var body: some View {
        GeometryReader { proxy in
            if let text {
                Text(text)
                    .font(.system(size: max(proxy.size.height * 0.045, 11), weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.85), radius: max(proxy.size.height * 0.012, 2))
                    .frame(maxWidth: proxy.size.width * 0.9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, proxy.size.height * 0.08)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One cue: its time, which seeks the player there, its text, and Merge with Next and Split.
private struct CueRow: View {
    let cue: SubtitleCue
    let isCurrent: Bool
    @Binding var text: String
    let canMerge: Bool
    let canSplit: Bool
    let seek: () -> Void
    let merge: () -> Void
    let split: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.small) {
                Button(SubtitleText.timeRange(of: cue), action: seek)
                    .buttonStyle(.link)
                    .font(.system(size: 11).monospacedDigit())
                    .help("Play from here")
                Spacer(minLength: 0)
                Button("Split", systemImage: "scissors", action: split)
                    .labelStyle(.iconOnly)
                    .disabled(!canSplit)
                    .help("Split this cue in two")
                Button("Merge with Next", systemImage: "arrow.down.right.and.arrow.up.left", action: merge)
                    .labelStyle(.iconOnly)
                    .disabled(!canMerge)
                    .help("Merge with the next cue")
            }
            .buttonStyle(.borderless)
            TextField("Text", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
        }
        .padding(8)
        .background(
            isCurrent ? Theme.well : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        )
        .listRowSeparator(.hidden)
    }
}
