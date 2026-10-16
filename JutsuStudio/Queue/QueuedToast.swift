import Presentation
import SwiftUI

extension View {
    /// Shows `NavigationModel.queuedNotice` at the bottom for a moment after a submit queued jobs, with a way
    /// to the Queue when it isn't on screen already; otherwise `draftReplacement`, with Undo.
    func queuedToast() -> some View {
        modifier(QueuedToast())
    }
}

private struct QueuedToast: ViewModifier {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice = navigation.queuedNotice {
                    toast(
                        icon: "checkmark.circle.fill", text: notice.text,
                        action: navigation.selection == .queue
                            ? nil
                            : (QueuedNotice.viewInQueue, { navigation.selection = .queue }),
                        dismiss: { navigation.queuedNotice = nil }
                    )
                    .shown(id: notice.id, text: notice.text, for: QueuedNotice.duration, reduceMotion: reduceMotion) {
                        guard navigation.queuedNotice?.id == notice.id else { return }
                        navigation.queuedNotice = nil
                    }
                } else if let replacement = navigation.draftReplacement {
                    toast(
                        icon: "arrow.uturn.backward.circle.fill", text: DraftReplacement.title,
                        action: (DraftReplacement.undo, { navigation.undo(replacement) }),
                        dismiss: { navigation.draftReplacement = nil }
                    )
                    .shown(
                        id: replacement.id, text: DraftReplacement.title, for: DraftReplacement.duration,
                        reduceMotion: reduceMotion
                    ) {
                        guard navigation.draftReplacement?.id == replacement.id else { return }
                        navigation.draftReplacement = nil
                    }
                }
            }
            .motionAnimation(.snappy(duration: 0.25), value: navigation.queuedNotice?.id)
            .motionAnimation(.snappy(duration: 0.25), value: navigation.draftReplacement?.id)
    }

    /// `action` runs after the toast is dismissed.
    private func toast(
        icon: String, text: String, action: (title: String, run: () -> Void)?, dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let action {
                Button(action.title) {
                    dismiss()
                    action.run()
                }
                .buttonStyle(.textLink)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.iconAction)
            .hoverHint("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Theme.Spacing.large)
        .padding(.trailing, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.background.opacity(0.92), in: Capsule())
        .background(Theme.glass, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.glassStroke, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Places a toast, announces `text` and calls `expire` after `duration` seconds unless a newer toast replaced it.
    fileprivate func shown(
        id: UUID, text: String, for duration: TimeInterval, reduceMotion: Bool,
        expire: @escaping @MainActor () -> Void
    ) -> some View {
        padding(.bottom, Theme.Spacing.xLarge)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .task(id: id) {
                AccessibilityNotification.Announcement(text).post()
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                expire()
            }
    }
}
