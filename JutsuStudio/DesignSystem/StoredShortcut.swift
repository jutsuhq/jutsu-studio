import AppKit
import Carbon
import Presentation
import SwiftUI

/// The keyboard shortcut Settings › Shortcuts set for `action`; `nil` once it was removed. Menus and buttons
/// pick up a change at once.
@propertyWrapper
struct StoredShortcut: DynamicProperty {
    @AppStorage private var stored: String
    private let action: ShortcutAction

    init(_ action: ShortcutAction) {
        self.action = action
        _stored = AppStorage(wrappedValue: "", action.storageKey)
    }

    var wrappedValue: KeyboardShortcut? { projectedValue.map(KeyboardShortcut.init) }

    /// For text such as a tooltip: `$shortcut?.displayText`.
    var projectedValue: Shortcut? { action.shortcut(stored: stored) }
}

extension KeyboardShortcut {
    init(_ shortcut: Shortcut) {
        var modifiers: SwiftUI.EventModifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        let key: KeyEquivalent =
            switch shortcut.key {
            case .character(let character): KeyEquivalent(character)
            case .return: .return
            case .space: .space
            case .tab: .tab
            case .delete: .delete
            case .leftArrow: .leftArrow
            case .rightArrow: .rightArrow
            case .upArrow: .upArrow
            case .downArrow: .downArrow
            }
        self.init(key, modifiers: modifiers)
    }
}

extension Shortcut {
    /// The shortcut a key press in a SwiftUI view makes; `nil` for a key with no character, such as F5.
    @MainActor init?(_ press: KeyPress) {
        // The event behind the press knows its key code, so a non-Latin layout still matches the Latin key.
        if let event = NSApp.currentEvent, event.type == .keyDown, let shortcut = Shortcut(event: event) {
            self = shortcut
            return
        }
        var modifiers: Modifiers = []
        if press.modifiers.contains(.command) { modifiers.insert(.command) }
        if press.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if press.modifiers.contains(.option) { modifiers.insert(.option) }
        if press.modifiers.contains(.control) { modifiers.insert(.control) }
        let named: [KeyEquivalent: Key] = [
            .return: .return, .space: .space, .tab: .tab, .delete: .delete, .leftArrow: .leftArrow,
            .rightArrow: .rightArrow, .upArrow: .upArrow, .downArrow: .downArrow,
        ]
        if let key = named[press.key] {
            self.init(key: key, modifiers: modifiers)
            return
        }
        let character = press.key.character
        guard !character.isWhitespace, character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 })
        else { return nil }
        self.init(key: .character(character), modifiers: modifiers)
    }

    /// Virtual key codes of the keys that have no character of their own.
    private static let namedKeys: [UInt16: Key] = [
        36: .return, 76: .return, 49: .space, 48: .tab, 51: .delete,
        123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow,
    ]

    /// The shortcut a key press makes; `nil` for a key with no character, such as F5.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if let key = Self.namedKeys[event.keyCode] {
            self.init(key: key, modifiers: modifiers)
            return
        }
        // From the Latin layout and unshifted: on a Russian layout the O key stays "o", not "щ", and ⇧⌘1 stays
        // "1" rather than "!", since menus match ⌘ shortcuts by the Latin key and show the shift separately.
        guard
            let character = Self.latinCharacter(keyCode: event.keyCode)
                ?? event.characters(byApplyingModifiers: [])?.first,
            !character.isWhitespace, character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 })
        else { return nil }
        self.init(key: .character(character), modifiers: modifiers)
    }

    /// The character `keyCode` types on the current ASCII-capable layout (U.S., ABC, or the Latin layout a
    /// Russian user switches to), without modifiers.
    private static func latinCharacter(keyCode: UInt16) -> Character? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).first
    }
}
