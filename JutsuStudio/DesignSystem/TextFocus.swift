import AppKit
import SwiftUI

/// Shortcuts that text editing uses too (⌘A, ⌘V, ⌘⌫) hand the key back to the text being edited.
@MainActor
enum TextFocus {
    /// Sends `action` to the text being edited in the key window, as the Edit menu would; `false` when no text is
    /// being edited, so the shortcut's own action should run.
    ///
    /// Sent on the next turn of the run loop: a `TextEditor` edited from inside a SwiftUI button's action takes the
    /// paste, then SwiftUI writes the binding's old value back over it.
    static func send(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        DispatchQueue.main.async { NSApp.sendAction(action, to: nil, from: nil) }
        return true
    }
}

/// An invisible button for a window shortcut that text editing also uses: while a text field is edited the key goes
/// to the text, otherwise `action` runs. A window shortcut runs before the Edit menu's item for the same key, so
/// without the hand-back a text field would lose it.
struct TextAwareShortcut: View {
    let title: LocalizedStringKey
    let key: KeyEquivalent
    let textAction: Selector
    let action: () -> Void

    init(_ title: LocalizedStringKey, key: KeyEquivalent, textAction: Selector, action: @escaping () -> Void) {
        (self.title, self.key, self.textAction, self.action) = (title, key, textAction, action)
    }

    var body: some View {
        Button(title) {
            if !TextFocus.send(textAction) { action() }
        }
        .keyboardShortcut(key, modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
