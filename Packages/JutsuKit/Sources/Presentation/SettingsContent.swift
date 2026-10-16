import Foundation
import JutsuCore

/// One label/value line of the Settings connection card.
public struct ConnectionRow: Sendable, Hashable, Identifiable {
    public var label: String
    public var value: String
    /// Key IDs read better in a fixed-width font.
    public var isMonospaced: Bool

    public init(label: String, value: String, isMonospaced: Bool = false) {
        self.label = label
        self.value = value
        self.isMonospaced = isMonospaced
    }

    public var id: String { label }
}

extension ConnectionState {
    /// The rows of the Settings connection card; empty when not connected.
    /// - Parameter capabilities: `nil` while they are still loading.
    public func cardRows(capabilities: Capabilities?, locale: Locale = .current) -> [ConnectionRow] {
        switch self {
        case .none:
            return []
        case .apiKey(let keyID):
            return [
                ConnectionRow(
                    label: String(localized: "Key ID", bundle: .module), value: Self.mask(keyID), isMonospaced: true),
                ConnectionRow(label: String(localized: "Secret", bundle: .module), value: "••••••••••••"),
                ConnectionRow(
                    label: String(localized: "Stored in", bundle: .module),
                    value: String(localized: "macOS Keychain", bundle: .module)),
            ]
        case .account(let info):
            var rows = [
                ConnectionRow(
                    label: String(localized: "Account", bundle: .module),
                    value: info.email ?? String(localized: "Signed in", bundle: .module))
            ]
            if let plan = info.plan {
                rows.append(ConnectionRow(label: String(localized: "Plan", bundle: .module), value: plan))
            }
            if let credits = info.credits {
                rows.append(
                    ConnectionRow(
                        label: String(localized: "Credits", bundle: .module),
                        value: Self.grouped(credits, locale: locale)))
            }
            rows.append(ConnectionRow(label: "Genjutsu", value: Self.modesText(capabilities)))
            return rows
        }
    }

    /// The first and last four characters of a long key ID.
    static func mask(_ keyID: String) -> String {
        guard keyID.count > 10 else { return keyID }
        return "\(keyID.prefix(4))…\(keyID.suffix(4))"
    }

    private static func modesText(_ capabilities: Capabilities?) -> String {
        guard let capabilities else { return String(localized: "Checking…", bundle: .module) }
        let titles = Mode.allCases.filter { capabilities.modes.contains($0) }.map(\.title)
        return titles.isEmpty ? String(localized: "None", bundle: .module) : titles.joined(separator: " · ")
    }

    /// Always groups thousands with the locale's separator. Darwin's ICU gives `en_US_POSIX` no grouping
    /// while swift-corelibs does, so grouping is switched on explicitly.
    static func grouped(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = true
        if formatter.groupingSize == 0 { formatter.groupingSize = 3 }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

extension Capabilities {
    /// What the unlimited allowance covers, for the Settings switch: "Genjutsu Motion Transfer · Seedance 2.5";
    /// `nil` when it covers nothing, and the switch isn't offered.
    public var unlimitedText: String? {
        let names = VideoModel.allCases.flatMap { model -> [String] in
            let modes = Mode.allCases.filter { unlimited[model]?.contains($0) == true }
            guard !modes.isEmpty else { return [] }
            return model == .genjutsu ? modes.map { "\(model.title) \($0.title)" } : [model.title]
        }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }
}

public enum DailySpend {
    /// `Budget.committed`: what the spend cap counts on `day`, the jobs and the reference image requests
    /// (`ImageCharge`). `SwiftDataStore.committedSpend` reads the jobs' part straight from the store.
    public static func committed(
        _ jobs: [Job], images: [ImageCharge] = [], on day: Date, in unit: Capabilities.CostUnit = .usd,
        calendar: Calendar = .current
    ) -> Decimal {
        Budget.committed(jobs, on: day, in: unit, calendar: calendar)
            + Budget.committed(images, on: day, in: unit, calendar: calendar)
    }
}

/// A ready-made file name pattern for the Settings menu.
public struct OutputNameTemplate: Sendable, Hashable, Identifiable {
    public var title: String
    public var pattern: String

    public var id: String { pattern }
}

/// Which job notifications the user wants. Paused counts as a problem: the job waits for the user.
public struct NotificationPreferences: Sendable, Hashable {
    public var onDone: Bool
    public var onProblems: Bool
    public var playsSound: Bool

    public init(onDone: Bool = true, onProblems: Bool = true, playsSound: Bool = true) {
        self.onDone = onDone
        self.onProblems = onProblems
        self.playsSound = playsSound
    }

    public static let off = NotificationPreferences(onDone: false, onProblems: false)

    func allows(_ kind: JobNotification.Kind) -> Bool {
        switch kind {
        case .done: onDone
        case .failed, .rejected, .paused: onProblems
        }
    }
}

/// The Open at Login switch, from `SMAppService` status.
public enum LoginItemStatus: Sendable, Hashable {
    case enabled
    case disabled
    /// Registered, but the user has to allow it in System Settings first.
    case requiresApproval

    public var isOn: Bool { self != .disabled }

    public var note: String? {
        self == .requiresApproval
            ? String(localized: "Allow Jutsu Studio in System Settings › General › Login Items.", bundle: .module) : nil
    }
}

public enum CacheSize {
    /// Total size of the regular files under `folders`, measured on a background thread.
    /// Missing folders count as empty.
    public static func bytes(in folders: [URL]) async -> Int64 {
        await Task.detached(priority: .utility) { measure(folders) }.value
    }

    static func measure(_ folders: [URL]) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var total: Int64 = 0
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
            else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                    continue
                }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
