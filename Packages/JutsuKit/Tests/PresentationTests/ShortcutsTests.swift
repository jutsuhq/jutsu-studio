import Foundation
import Testing

@testable import Presentation

struct ShortcutsTests {
    @Test func aShortcutRoundTripsThroughItsStoredText() {
        let shortcuts = [
            Shortcut(key: .character("K"), modifiers: [.command, .shift]),
            Shortcut(key: .return, modifiers: .command),
            Shortcut(key: .character("+"), modifiers: [.control, .option]),
            Shortcut(key: .leftArrow, modifiers: [.command, .option]),
        ]
        for shortcut in shortcuts {
            #expect(Shortcut(shortcut.stored) == shortcut)
        }
        #expect(shortcuts[0].stored == "shift+cmd+k")
        #expect(shortcuts[2].stored == "ctrl+opt++")
    }

    @Test func theDisplayFollowsTheMenuOrder() {
        #expect(
            Shortcut(key: .character("k"), modifiers: [.command, .shift, .control, .option]).displayText == "⌃⌥⇧⌘K")
        #expect(Shortcut(key: .return, modifiers: .command).displayText == "⌘↩")
        #expect(ShortcutAction.create.defaultShortcut.displayText == "⌘1")
    }

    @Test(arguments: ["", "cmd+", "hyper+k", "cmd+kk", "+"])
    func textThatIsntAShortcutDoesntParse(_ text: String) {
        #expect(Shortcut(text) == nil)
    }

    @Test func storedValuesResolveToDefaultsAndRemovals() {
        #expect(ShortcutAction.queue.shortcut(stored: "") == ShortcutAction.queue.defaultShortcut)
        #expect(ShortcutAction.queue.shortcut(stored: ShortcutAction.none) == nil)
        #expect(ShortcutAction.queue.shortcut(stored: "garbage+x") == ShortcutAction.queue.defaultShortcut)
        #expect(
            ShortcutAction.queue.shortcut(stored: "opt+cmd+q")
                == Shortcut(key: .character("q"), modifiers: [.command, .option]))
    }

    @Test func theDefaultsDontClashOrHitReservedKeys() {
        let defaults = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        for action in ShortcutAction.allCases {
            #expect(action.defaultShortcut.refusal(for: action, assigned: defaults) == nil)
        }
    }

    @Test func aRecordedShortcutIsRefusedWhenItCantWork() {
        let assigned = [ShortcutAction.queue: ShortcutAction.queue.defaultShortcut]
        #expect(
            Shortcut(key: .character("k"), modifiers: .shift).refusal(for: .create, assigned: assigned)
                == .needsModifier)
        #expect(
            Shortcut(key: .character("q"), modifiers: .command).refusal(for: .create, assigned: assigned) == .reserved)
        #expect(ShortcutAction.queue.defaultShortcut.refusal(for: .create, assigned: assigned) == .usedBy(.queue))
        #expect(ShortcutAction.queue.defaultShortcut.refusal(for: .queue, assigned: assigned) == nil)
        #expect(Shortcut(key: .character("k"), modifiers: .control).refusal(for: .create, assigned: assigned) == nil)
    }

    @Test func cullingKeysTakeASingleKeyButNotOneTheGridUses() {
        let defaults = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        let k = Shortcut(key: .character("k"), modifiers: [])
        #expect(k.refusal(for: .keep, assigned: defaults) == nil)
        #expect(k.refusal(for: .star, assigned: defaults) == .needsModifier)
        #expect(Shortcut(key: .space, modifiers: []).refusal(for: .keep, assigned: defaults) == .reserved)
        #expect(Shortcut(key: .rightArrow, modifiers: []).refusal(for: .reject, assigned: defaults) == .reserved)
        #expect(
            Shortcut(key: .character("z"), modifiers: .command).refusal(for: .keep, assigned: defaults) == .reserved)
        // Each culling key against the existing table: the others' keys and the app's ⌘ shortcuts.
        #expect(ShortcutAction.reject.defaultShortcut.refusal(for: .keep, assigned: defaults) == .usedBy(.reject))
        #expect(ShortcutAction.star.defaultShortcut.refusal(for: .clearCulling, assigned: defaults) == .usedBy(.star))
        #expect(ShortcutAction.keep.defaultShortcut.refusal(for: .create, assigned: defaults) == .needsModifier)
        #expect(
            ShortcutAction.keep.keyPress(k, isEscape: false, isDelete: false, assigned: defaults) == .save("k"))
    }

    @Test func aKeyPressWhileRecordingSavesRemovesCancelsOrRefuses() {
        let assigned = [ShortcutAction.queue: ShortcutAction.queue.defaultShortcut]
        let new = Shortcut(key: .character("k"), modifiers: [.command, .shift])
        #expect(ShortcutAction.create.keyPress(new, isEscape: true, isDelete: false, assigned: assigned) == .cancel)
        #expect(
            ShortcutAction.create.keyPress(nil, isEscape: false, isDelete: true, assigned: assigned)
                == .save(ShortcutAction.none))
        #expect(ShortcutAction.create.keyPress(nil, isEscape: false, isDelete: false, assigned: assigned) == .ignore)
        #expect(
            ShortcutAction.create.keyPress(new, isEscape: false, isDelete: false, assigned: assigned)
                == .save("shift+cmd+k"))
        #expect(
            ShortcutAction.create.keyPress(
                ShortcutAction.create.defaultShortcut, isEscape: false, isDelete: false, assigned: assigned)
                == .save(""))
        #expect(
            ShortcutAction.create.keyPress(
                ShortcutAction.queue.defaultShortcut, isEscape: false, isDelete: false, assigned: assigned)
                == .refuse(.usedBy(.queue)))
    }
}
