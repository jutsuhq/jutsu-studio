import AppKit
import Presentation
import SwiftUI

/// The status item: the app mark as a template image, outlined while idle and filled while work runs, with a thin bar
/// under it for how far the work is (`MenuBarPanel.iconProgress`). It hands the window action to `SystemIntegration`
/// whenever it is shown.
struct MenuBarLabel: View {
    @Environment(LiveJobs.self) private var liveJobs
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(AppSettings.showActiveCountKey) private var showsCount = AppSettings.defaultShowActiveCount
    let system: SystemIntegration

    /// What the label shows, set by `follow()` alone: the body reads no job or run, so a progress report doesn't
    /// evaluate it again.
    @State private var shown = Shown(active: 0, progress: nil)

    /// How often the bar moves while work runs: a generating job's estimate moves with time, not with events, and a
    /// step of the bar is a twelfth of the work.
    private static let step: TimeInterval = 10

    private struct Shown: Equatable {
        var active: Int
        var progress: Double?
    }

    var body: some View {
        label(shown)
            .task { await follow() }
            .capturesOpenWindow(for: system)
    }

    private func label(_ shown: Shown) -> some View {
        HStack(spacing: 2) {
            Image(nsImage: MenuBarIcon.image(progress: shown.progress))
                .accessibilityLabel(MenuBarPanel.accessibilityLabel(activeCount: shown.active))
                .accessibilityValue(shown.progress.map { CostText.percent(fraction: $0) } ?? "")
            if let text = MenuBarPanel.countText(activeCount: shown.active, isShown: showsCount) {
                Text(text)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
    }

    /// Sets `shown` as work starts or ends, and at most every `step` while it runs. A TimelineView in the label makes
    /// the extra redraw its button endlessly.
    private func follow() async {
        var stepped = Date.distantPast
        while !Task.isCancelled {
            let now = Date.now
            let active = liveJobs.activeCount + environment.onDevice.runs.count + environment.subtitles.runs.count
            if active != shown.active || (active > 0 && now.timeIntervalSince(stepped) >= Self.step) {
                let next = Shown(active: active, progress: active == 0 ? nil : progress(now: now))
                if next != shown { shown = next }
                stepped = now
            }
            await nextChange(timeout: active > 0 ? Self.step - now.timeIntervalSince(stepped) : nil)
        }
    }

    /// Returns at the next change of a job's state or of the runs on this Mac, or after `timeout`. A run's progress
    /// report wakes it too; `follow` then only counts the work.
    private func nextChange(timeout: TimeInterval?) async {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        withObservationTracking {
            _ = liveJobs.stateRevision
            _ = environment.onDevice.runs
            _ = environment.subtitles.runs
        } onChange: {
            continuation.yield()
        }
        let timer = timeout.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(max(seconds, 0)))
                continuation.yield()
            }
        }
        for await _ in changes { break }
        timer?.cancel()
        continuation.finish()
    }

    private func progress(now: Date) -> Double? {
        MenuBarPanel.iconProgress(
            jobs: liveJobs.active,
            runs: environment.onDevice.runs.map(MenuBarPanel.Run.init)
                + environment.subtitles.runs.map(MenuBarPanel.Run.init),
            now: now, times: liveJobs.generationTimes) ?? 0
    }
}

/// The status item's template images, one per progress step, drawn once and kept.
@MainActor
enum MenuBarIcon {
    private static var cache: [Int: NSImage] = [:]
    static let size = NSSize(width: 18, height: 18)

    /// `nil`: idle, the outlined mark. Else the filled mark over a bar `progress` full.
    static func image(progress: Double?) -> NSImage {
        let step = progress.map { Int(($0 * Double(MenuBarPanel.iconSteps)).rounded(.down)) } ?? -1
        if let image = cache[step] { return image }
        let image = draw(step: step)
        cache[step] = image
        return image
    }

    private static func draw(step: Int) -> NSImage {
        guard step >= 0, let mark = NSImage(named: "MenuBarRunning") else {
            return NSImage(named: "MenuBarIdle") ?? NSImage(size: size)
        }
        let image = NSImage(size: size, flipped: false) { _ in
            // The mark a little smaller and higher, the bar along the bottom.
            mark.draw(in: NSRect(x: 2, y: 3.5, width: 14.5, height: 14.5))
            let track = NSRect(x: 2.5, y: 0.5, width: 13, height: 2)
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
            let fraction = CGFloat(step) / CGFloat(MenuBarPanel.iconSteps)
            if fraction > 0 {
                var filled = track
                filled.size.width = max(2, track.width * fraction)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: filled, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Whether the panel's window is on screen, for the timeline and the budget read, which run only while it is.
struct PanelVisibility: NSViewRepresentable {
    @Binding var isOpen: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = { isOpen = $0 }
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.changed = { isOpen = $0 }
    }

    /// Its observers go when it leaves its window (`viewDidMoveToWindow` with none), which happens before it is freed.
    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
            }
            report()
        }

        private func report() {
            guard let window else { return }
            changed?(window.isVisible && window.occlusionState.contains(.visible))
        }
    }
}
