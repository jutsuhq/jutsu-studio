import Foundation

/// The app's commands whose keyboard shortcut can be changed in Settings › Shortcuts. Keys that work only in one
/// place (arrows, Space, Escape, Return in a dialog) and the system's own (⌘, ⌘Q, ⌃⌘S) stay fixed.
public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case create, queue, library, open, generate, find, refreshHistory, star, deleteResult, cancelJob, retryJob
    case keep, reject, clearCulling

    public var id: Self { self }

    /// Culling keys work only while the Library's grid or large viewer has the keyboard, never in a text field, so
    /// they take a single key, the way photo culling does.
    public var isLibraryKey: Bool {
        switch self {
        case .keep, .reject, .clearCulling: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .create: String(localized: "Show Create", bundle: .module)
        case .queue: String(localized: "Show Queue", bundle: .module)
        case .library: String(localized: "Show Library", bundle: .module)
        case .open: String(localized: "Open a video or images", bundle: .module)
        case .generate: String(localized: "Generate", bundle: .module)
        case .find: String(localized: "Search a gallery", bundle: .module)
        case .refreshHistory: String(localized: "Refresh Higgsfield history", bundle: .module)
        case .star: String(localized: "Star or unstar results", bundle: .module)
        case .deleteResult: String(localized: "Delete results from Library", bundle: .module)
        case .cancelJob: String(localized: "Cancel the selected job", bundle: .module)
        case .retryJob: String(localized: "Retry the selected job", bundle: .module)
        case .keep: String(localized: "Keep results in Library", bundle: .module)
        case .reject: String(localized: "Reject results in Library", bundle: .module)
        case .clearCulling: String(localized: "Clear keep or reject", bundle: .module)
        }
    }

    public var defaultShortcut: Shortcut {
        switch self {
        case .create: Shortcut(key: .character("1"), modifiers: .command)
        case .queue: Shortcut(key: .character("2"), modifiers: .command)
        case .library: Shortcut(key: .character("3"), modifiers: .command)
        case .open: Shortcut(key: .character("o"), modifiers: .command)
        case .generate: Shortcut(key: .return, modifiers: .command)
        case .find: Shortcut(key: .character("f"), modifiers: .command)
        case .refreshHistory: Shortcut(key: .character("r"), modifiers: .command)
        case .star: Shortcut(key: .character("l"), modifiers: .command)
        case .deleteResult: Shortcut(key: .delete, modifiers: .command)
        // ⌘. is the Mac's "stop what's running".
        case .cancelJob: Shortcut(key: .character("."), modifiers: .command)
        case .retryJob: Shortcut(key: .character("r"), modifiers: [.command, .shift])
        // P for pick, X for reject, U for unflag: the keys photo culling apps use.
        case .keep: Shortcut(key: .character("p"), modifiers: [])
        case .reject: Shortcut(key: .character("x"), modifiers: [])
        case .clearCulling: Shortcut(key: .character("u"), modifiers: [])
        }
    }

    /// `@AppStorage` key. Absent or empty means the default; `ShortcutAction.none` means no shortcut.
    public var storageKey: String { "shortcuts.\(rawValue)" }

    /// The stored value of an action whose shortcut was removed.
    public static let none = "none"

    /// The shortcut `stored` (the `storageKey` value) sets; `nil` when it was removed.
    public func shortcut(stored: String) -> Shortcut? {
        if stored.isEmpty { return defaultShortcut }
        if stored == Self.none { return nil }
        return Shortcut(stored) ?? defaultShortcut
    }
}

/// A key with its modifiers, stored as text such as `cmd+shift+k` or `cmd+return`.
public struct Shortcut: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        /// A lowercased letter, digit or punctuation character.
        case character(Character)
        case `return`, space, tab, delete, leftArrow, rightArrow, upArrow, downArrow
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers) {
        if case .character(let character) = key {
            self.key = .character(Character(character.lowercased()))
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    /// A modifier or key with its stored name and the symbol menus show.
    private struct Name<Value: Sendable>: Sendable {
        let value: Value
        let stored: String
        let symbol: String

        init(_ value: Value, _ stored: String, _ symbol: String) {
            (self.value, self.stored, self.symbol) = (value, stored, symbol)
        }
    }

    private static let modifierNames: [Name<Modifiers>] = [
        Name(.control, "ctrl", "⌃"), Name(.option, "opt", "⌥"), Name(.shift, "shift", "⇧"), Name(.command, "cmd", "⌘"),
    ]
    private static let keyNames: [Name<Key>] = [
        Name(.return, "return", "↩"), Name(.space, "space", String(localized: "Space", bundle: .module)),
        Name(.tab, "tab", "⇥"),
        Name(.delete, "delete", "⌫"), Name(.leftArrow, "left", "←"), Name(.rightArrow, "right", "→"),
        Name(.upArrow, "up", "↑"), Name(.downArrow, "down", "↓"),
    ]

    /// Parses the stored form; `nil` for text that isn't one.
    public init?(_ stored: String) {
        // The key comes last and may itself be "+".
        let last: String
        let prefix: Substring
        if stored.hasSuffix("++") {
            (last, prefix) = ("+", stored.dropLast(2))
        } else if let separator = stored.lastIndex(of: "+") {
            (last, prefix) = (String(stored[stored.index(after: separator)...]), stored[..<separator])
        } else {
            (last, prefix) = (stored, "")
        }
        guard !last.isEmpty else { return nil }
        var modifiers: Modifiers = []
        for part in prefix.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        where !prefix.isEmpty {
            guard let modifier = Self.modifierNames.first(where: { $0.stored == part })?.value else { return nil }
            modifiers.insert(modifier)
        }
        if let key = Self.keyNames.first(where: { $0.stored == last })?.value {
            self.init(key: key, modifiers: modifiers)
        } else if last.count == 1, let character = last.first {
            self.init(key: .character(character), modifiers: modifiers)
        } else {
            return nil
        }
    }

    public var stored: String {
        let names = Self.modifierNames.filter { modifiers.contains($0.value) }.map(\.stored)
        return (names + [keyName]).joined(separator: "+")
    }

    /// As menus show it, e.g. `⇧⌘K`.
    public var displayText: String {
        Self.modifierNames.filter { modifiers.contains($0.value) }.map(\.symbol).joined() + keySymbol
    }

    private var keyName: String {
        if case .character(let character) = key { return String(character) }
        return Self.keyNames.first { $0.value == key }?.stored ?? ""
    }

    private var keySymbol: String {
        if case .character(let character) = key { return character.uppercased() }
        return Self.keyNames.first { $0.value == key }?.symbol ?? ""
    }
}

/// Why a recorded shortcut can't be used, as the recorder shows it.
public enum ShortcutRefusal: Equatable, Sendable {
    /// Without ⌘, ⌃ or ⌥ it would fire while typing.
    case needsModifier
    case reserved
    case usedBy(ShortcutAction)

    public var message: String {
        switch self {
        case .needsModifier: String(localized: "Add ⌘, ⌃ or ⌥ so it doesn't fire while typing", bundle: .module)
        case .reserved: String(localized: "macOS or the app already uses it", bundle: .module)
        case .usedBy(let action): String(localized: "Already used by \(action.title)", bundle: .module)
        }
    }
}

extension Shortcut {
    /// Shortcuts of the system and of the app's fixed commands.
    static let reserved: Set<Shortcut> = {
        let command: [Character] = ["q", "w", "h", "m", "n", ",", "a", "c", "v", "x", "z", "s", "p", "?", "`"]
        return Set(command.map { Shortcut(key: .character($0), modifiers: .command) }).union([
            Shortcut(key: .character("z"), modifiers: [.command, .shift]),
            Shortcut(key: .character("s"), modifiers: [.command, .control]),
            Shortcut(key: .character("f"), modifiers: [.command, .control]),
            Shortcut(key: .character("h"), modifiers: [.command, .option]),
            Shortcut(key: .character("w"), modifiers: [.command, .option]),
            Shortcut(key: .tab, modifiers: .command),
            Shortcut(key: .space, modifiers: .command),
            Shortcut(key: .space, modifiers: .control),
        ])
    }()

    /// Keys the Library's grid and large viewer already use without a modifier: moving, Quick Look, opening.
    static let libraryReserved: Set<Key> = [
        .space, .return, .tab, .delete, .leftArrow, .rightArrow, .upArrow, .downArrow,
    ]

    /// Whether `action` can take this shortcut while the others keep `assigned`; `nil` when it can.
    public func refusal(for action: ShortcutAction, assigned: [ShortcutAction: Shortcut]) -> ShortcutRefusal? {
        let isPlain = modifiers.isDisjoint(with: [.command, .control, .option])
        if isPlain, !action.isLibraryKey { return .needsModifier }
        if isPlain, Self.libraryReserved.contains(key) { return .reserved }
        if Self.reserved.contains(self) { return .reserved }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && assigned[$0] == self }) {
            return .usedBy(other)
        }
        return nil
    }
}

/// What a key press does while the shortcut of an action is being recorded.
public enum ShortcutKeyPress: Equatable, Sendable {
    /// Escape: stop recording, keep the shortcut.
    case cancel
    /// Store this value (`storageKey`) and stop: a shortcut, `ShortcutAction.none`, or "" for the default.
    case save(String)
    case refuse(ShortcutRefusal)
    /// A key that makes no shortcut, such as F5; keep recording.
    case ignore
}

extension ShortcutAction {
    /// `shortcut` is the key press, `nil` for a key without a character. Escape and Delete only count without
    /// modifiers; with them they are shortcuts like any other.
    public func keyPress(
        _ shortcut: Shortcut?, isEscape: Bool, isDelete: Bool, assigned: [ShortcutAction: Shortcut]
    ) -> ShortcutKeyPress {
        if isEscape { return .cancel }
        if isDelete { return .save(Self.none) }
        guard let shortcut else { return .ignore }
        if let refusal = shortcut.refusal(for: self, assigned: assigned) { return .refuse(refusal) }
        return .save(shortcut == defaultShortcut ? "" : shortcut.stored)
    }
}
