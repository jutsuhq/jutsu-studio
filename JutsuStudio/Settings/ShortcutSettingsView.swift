import AppKit
import Presentation
import SwiftUI

/// Settings › Shortcuts: click a shortcut, then press the new keys. Escape cancels, Delete removes it.
struct ShortcutSettingsView: View {
    @State private var recording: ShortcutAction?
    @State private var refusal: (action: ShortcutAction, reason: ShortcutRefusal)?
    @State private var monitor: Any?
    /// Bumped on every change, so the rows read the stored values again.
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            SettingsSection(
                title: "Keyboard",
                footer: String(
                    localized: """
                        Click a shortcut and press the new keys. Escape cancels, Delete removes it. \
                        ⌘, (Settings) and the system's shortcuts stay as they are. Keep, Reject and Clear work only \
                        in the Library's grid and result page, so they can be a single key.
                        """)
            ) {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                    SettingsRow(label: action.title, detail: refusalText(for: action), isFirst: index == 0) {
                        HStack(spacing: Theme.Spacing.small) {
                            if stored(action) != nil {
                                Button("Reset", systemImage: "arrow.counterclockwise") { save("", for: action) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.muted)
                                    .hoverHint("Back to \(action.defaultShortcut.displayText)")
                                    .accessibilityLabel("Reset \(action.title)")
                            }
                            recorder(for: action)
                        }
                    }
                }
            }
            .id(revision)
            Button("Restore Defaults") {
                for action in ShortcutAction.allCases { UserDefaults.standard.removeObject(forKey: action.storageKey) }
                refusal = nil
                revision += 1
            }
            .buttonStyle(.secondaryAction)
            .disabled(ShortcutAction.allCases.allSatisfy { stored($0) == nil })
        }
        .onDisappear(perform: stopRecording)
    }

    private func recorder(for action: ShortcutAction) -> some View {
        let isRecording = recording == action
        let current = action.shortcut(stored: stored(action) ?? "")
        return Button {
            isRecording ? stopRecording() : startRecording(action)
        } label: {
            Text(isRecording ? String(localized: "Type shortcut…") : current?.displayText ?? String(localized: "None"))
                .font(.system(size: 13, weight: .medium, design: isRecording ? .default : .rounded))
                .foregroundStyle(isRecording ? Theme.accent : current == nil ? Theme.faint : Theme.text)
                .frame(minWidth: 120, minHeight: 28)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isRecording ? Theme.accent : Theme.stroke, lineWidth: isRecording ? 1.5 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(current?.displayText ?? String(localized: "None"))
    }

    private func refusalText(for action: ShortcutAction) -> String? {
        guard let refusal, refusal.action == action else { return nil }
        return refusal.reason.message
    }

    // MARK: Recording

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        refusal = nil
        // A local monitor sees the keys before the menus, so recording ⌘1 doesn't also switch the page.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // AppKit calls local monitors on the main thread.
            MainActor.assumeIsolated { record(event, for: action) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func record(_ event: NSEvent, for action: ShortcutAction) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        // Escape; Delete and Forward Delete.
        let press = action.keyPress(
            Shortcut(event: event), isEscape: plain && event.keyCode == 53,
            isDelete: plain && [51, 117].contains(event.keyCode), assigned: assigned())
        switch press {
        case .cancel:
            stopRecording()
        case .save(let value):
            save(value, for: action)
            stopRecording()
        case .refuse(let reason):
            refusal = (action, reason)
            NSSound.beep()
        case .ignore:
            break
        }
    }

    // MARK: Storage

    /// The value stored for `action`; `nil` while it keeps its default.
    private func stored(_ action: ShortcutAction) -> String? {
        _ = revision
        let value = UserDefaults.standard.string(forKey: action.storageKey) ?? ""
        return value.isEmpty ? nil : value
    }

    private func save(_ value: String, for action: ShortcutAction) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: action.storageKey)
        } else {
            UserDefaults.standard.set(value, forKey: action.storageKey)
        }
        refusal = nil
        revision += 1
    }

    private func assigned() -> [ShortcutAction: Shortcut] {
        var assigned: [ShortcutAction: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            assigned[action] = action.shortcut(stored: stored(action) ?? "")
        }
        return assigned
    }
}
