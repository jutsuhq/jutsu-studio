import Foundation
import JutsuCore

/// `@AppStorage` keys and defaults, shared by the composition root, Create and the Settings page.
/// Every reader goes through these functions so a missing or out-of-range value means the default.
public enum AppSettings {
    public static let defaultResolutionKey = "settings.defaultResolution"
    public static let maxConcurrencyKey = "settings.maxConcurrency"
    public static let spendCapEnabledKey = "settings.spendCapEnabled"
    public static let spendCapUSDKey = "settings.spendCapUSD"
    /// The key predates the split by kind, so it now holds the "done" switch.
    public static let notifyOnDoneKey = "settings.notifyOnFinish"
    /// Failed, rejected and paused.
    public static let notifyOnProblemsKey = "settings.notifyOnProblems"
    public static let notificationSoundKey = "settings.notificationSound"
    public static let spendCapCreditsEnabledKey = "settings.spendCapCreditsEnabled"
    public static let spendCapCreditsKey = "settings.spendCapCredits"
    public static let lowCreditThresholdKey = "settings.lowCreditThreshold"
    /// The account pays from the plan's unlimited allowance where `models_explore` says it applies.
    public static let useUnlimitedKey = "settings.useUnlimited"
    public static let draftResolutionKey = "settings.draftResolution"
    public static let defaultModeKey = "settings.defaultMode"
    public static let showInMenuBarKey = "settings.showInMenuBar"
    public static let showActiveCountKey = "settings.showActiveCount"
    /// Security-scoped bookmark of a custom output folder; absent means the default folder.
    public static let outputFolderBookmarkKey = "settings.outputFolderBookmark"
    /// JSON `OutputFolderHistory`: custom folders picked before the current one that may still hold results.
    public static let previousOutputFoldersKey = "settings.previousOutputFolders"
    public static let outputNamePatternKey = "settings.outputNamePattern"
    /// Seconds since 1970 of the last "Clear prompt history"; 0 means never cleared.
    public static let promptHistoryClearedAtKey = "settings.promptHistoryClearedAt"
    /// JSON `[StylePreset]` snapshots, newest first; see `PresetShelf`.
    public static let favoritePresetsKey = "presets.favorites"
    public static let recentPresetsKey = "presets.recent"
    /// JSON `[ImageModel]`: the connection's image models as last loaded, shown at once on the next launch.
    public static func imageModelsKey(kind: ProviderKind, owner: String?) -> String {
        "images.models.\(kind.rawValue).\(owner ?? "")"
    }
    /// Seconds since 1970 of the Queue's last "Clear all" of jobs that didn't finish; 0 means never.
    public static let queueProblemsClearedAtKey = "queue.problemsClearedAt"
    /// Comma-separated ids of the jobs removed from the Queue's "Didn't finish" section; see `QueueProblems`.
    public static let queueRemovedProblemsKey = "queue.removedProblems"

    public static let defaultResolution = Resolution.p480
    /// Parallel jobs for an API key, whose Higgsfield limit is low.
    public static let defaultMaxConcurrency = 2
    /// Parallel jobs for an account. Higgsfield names no limit for a plan; a refusal lowers it until the next launch.
    public static let defaultAccountMaxConcurrency = 8
    public static let maxConcurrencyRange = 1...40
    public static let defaultSpendCapEnabled = true
    public static let defaultSpendCapUSD = 75.0
    /// Off: an account had no cap before, its plan limits it.
    public static let defaultSpendCapCreditsEnabled = false
    public static let defaultSpendCapCredits = 1_000
    public static let defaultLowCreditThreshold = 50
    /// Off: unlimited generations are spent only after the user chose to.
    public static let defaultUseUnlimited = false
    public static let defaultNotify = true
    public static let defaultNotificationSound = true
    public static let defaultDraftResolution = Resolution.p480
    public static let defaultMode = Mode.motionTransfer
    public static let defaultShowInMenuBar = true
    public static let defaultShowActiveCount = false

    public static func clampConcurrency(_ value: Int) -> Int {
        min(max(value, maxConcurrencyRange.lowerBound), maxConcurrencyRange.upperBound)
    }

    /// Brings values stored by earlier versions to the current keys. Run once at launch, before any view reads them.
    public static func migrate(_ defaults: UserDefaults) {
        // One switch used to cover every kind; whoever turned it off keeps problems quiet too.
        if defaults.object(forKey: notifyOnProblemsKey) == nil, let notify = defaults.object(forKey: notifyOnDoneKey) {
            defaults.set(notify, forKey: notifyOnProblemsKey)
        }
    }

    public static func defaultResolution(in defaults: UserDefaults) -> Resolution {
        defaults.string(forKey: defaultResolutionKey).flatMap(Resolution.init(rawValue:)) ?? defaultResolution
    }

    public static func draftResolution(in defaults: UserDefaults) -> Resolution {
        defaults.string(forKey: draftResolutionKey).flatMap(Resolution.init(rawValue:)) ?? defaultDraftResolution
    }

    public static func defaultMode(in defaults: UserDefaults) -> Mode {
        defaults.string(forKey: defaultModeKey).flatMap(Mode.init(rawValue:)) ?? defaultMode
    }

    /// What runs at once when nothing is set in Settings: more for an account than for an API key.
    public static func defaultMaxConcurrency(for connection: ProviderKind?) -> Int {
        connection == .account ? defaultAccountMaxConcurrency : defaultMaxConcurrency
    }

    /// The limit set in Settings, else the connection's default.
    public static func maxConcurrency(in defaults: UserDefaults, for connection: ProviderKind?) -> Int {
        guard defaults.object(forKey: maxConcurrencyKey) != nil else { return defaultMaxConcurrency(for: connection) }
        return clampConcurrency(defaults.integer(forKey: maxConcurrencyKey))
    }

    /// `stored` from `@AppStorage`, or the connection's default when nothing is set.
    public static func maxConcurrency(stored: Int?, for connection: ProviderKind?) -> Int {
        stored.map(clampConcurrency) ?? defaultMaxConcurrency(for: connection)
    }

    /// The daily cap for `Budget` on `connection`: USD for an API key, credits for an account.
    /// `nil` when that cap is off or nothing is connected.
    public static func spendCap(in defaults: UserDefaults, for connection: ProviderKind?) -> SpendCap? {
        switch connection {
        case .apiKey?:
            let enabled = defaults.object(forKey: spendCapEnabledKey) as? Bool ?? defaultSpendCapEnabled
            guard enabled else { return nil }
            let amount = defaults.object(forKey: spendCapUSDKey) as? Double ?? defaultSpendCapUSD
            return .usd(cents(amount > 0 && amount.isFinite ? amount : defaultSpendCapUSD))
        case .account?:
            let enabled = defaults.object(forKey: spendCapCreditsEnabledKey) as? Bool ?? defaultSpendCapCreditsEnabled
            guard enabled else { return nil }
            let amount = defaults.object(forKey: spendCapCreditsKey) as? Int ?? defaultSpendCapCredits
            return .credits(amount > 0 ? amount : defaultSpendCapCredits)
        case nil:
            return nil
        }
    }

    public static func usesUnlimited(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: useUnlimitedKey) as? Bool ?? defaultUseUnlimited
    }

    public static func notificationPreferences(in defaults: UserDefaults) -> NotificationPreferences {
        NotificationPreferences(
            onDone: defaults.object(forKey: notifyOnDoneKey) as? Bool ?? defaultNotify,
            onProblems: defaults.object(forKey: notifyOnProblemsKey) as? Bool ?? defaultNotify,
            playsSound: defaults.object(forKey: notificationSoundKey) as? Bool ?? defaultNotificationSound)
    }

    public static func outputFolderBookmark(in defaults: UserDefaults) -> Data? {
        defaults.data(forKey: outputFolderBookmarkKey)
    }

    /// The stored `promptHistoryClearedAtKey` value as a date; `nil` when history was never cleared.
    public static func promptHistoryClearedAt(_ stored: Double) -> Date? {
        stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    public static func outputNamePattern(in defaults: UserDefaults) -> OutputNamePattern {
        OutputNamePattern(defaults.string(forKey: outputNamePatternKey) ?? OutputNamePattern.defaultPattern)
    }

    /// Ready-made patterns for the Settings menu; the first is the default.
    public static let outputNameTemplates = [
        OutputNameTemplate(
            title: String(localized: "Date, mode, ID (default)", bundle: .module),
            pattern: OutputNamePattern.defaultPattern),
        OutputNameTemplate(
            title: String(localized: "Date and time, mode, ID", bundle: .module), pattern: "{date}_{time}_{mode}_{id}"),
        OutputNameTemplate(
            title: String(localized: "Mode, preset, resolution, ID", bundle: .module),
            pattern: "{mode}_{preset}_{res}_{id}"),
        OutputNameTemplate(
            title: String(localized: "Date, draft mark, mode, resolution, ID", bundle: .module),
            pattern: "{date}_{draft}_{mode}_{res}_{id}"),
    ]

    /// The name `pattern` gives a 720p restyle with the "Claymation" preset queued at `date`, for Settings.
    public static func outputNameExample(
        _ pattern: String, date: Date = Date(), timeZone: TimeZone = .current
    ) -> String {
        let source = SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/example.mov"), duration: 10,
            pixelSize: PixelSize(width: 1280, height: 720), range: 0...10)
        let spec = JobSpec(mode: .restyle, source: source, presetID: UUID(), resolution: .p720)
        let id = UUID(uuid: (0x1a, 0x2b, 0x3c, 0x4d, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let job = Job(id: id, spec: spec, providerKind: .apiKey, cost: .usd(0, isEstimate: true), createdAt: date)
        return OutputNamePattern(pattern).fileName(for: job, presetName: "Claymation", timeZone: timeZone)
    }

    // MARK: Cap amount

    /// Accepts "75", "$75.00", "1,000.5" and surrounding spaces; `nil` for anything else, a non-positive amount or
    /// one of a billion dollars or more. The result is rounded to cents.
    public static func parseCapAmount(_ text: String) -> Double? {
        let cleaned = text.filter { !$0.isWhitespace && $0 != "," }
        let digits = cleaned.hasPrefix("$") ? String(cleaned.dropFirst()) : cleaned
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            let value = Double(digits), value > 0, value < 1_000_000_000
        else { return nil }
        return (value * 100).rounded() / 100
    }

    /// "$75.00" in en_US. The cap field passes en_US, because `parseCapAmount` reads its text back.
    public static func formatUSD(_ amount: Double, locale: Locale = CostText.locale) -> String {
        CostText.usd(Decimal(amount), digits: 2, locale: locale)
    }

    public static func formatUSD(_ amount: Decimal, locale: Locale = CostText.locale) -> String {
        CostText.usd(amount, digits: 2, locale: locale)
    }

    /// Accepts "1000", "1,000", "1 000 cr" and "1000 credits"; `nil` for anything else or a non-positive amount.
    public static func parseCapCredits(_ text: String) -> Int? {
        var cleaned = text.lowercased().filter { !$0.isWhitespace && $0 != "," }
        for suffix in ["credits", "cr"] where cleaned.hasSuffix(suffix) {
            cleaned.removeLast(suffix.count)
            break
        }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(cleaned), value > 0
        else { return nil }
        return value
    }

    /// "1,000 credits", "1 credit"; grouped with the locale's separator.
    public static func formatCredits(_ amount: Int, locale: Locale = .current) -> String {
        String(localized: "\(amount) credits", bundle: .module, locale: locale)
    }

    /// Today's spend in the cap's unit, as the Settings page shows it.
    public static func formatSpend(_ amount: Decimal, unit: Capabilities.CostUnit, locale: Locale = .current) -> String
    {
        switch unit {
        case .usd: formatUSD(amount)
        case .credits: formatCredits(NSDecimalNumber(decimal: amount).intValue, locale: locale)
        }
    }

    private static func cents(_ amount: Double) -> Decimal {
        // Through Decimal, not Int: a stored amount from before the upper bound could be too big for an Int.
        Decimal((amount * 100).rounded()) / 100
    }

    // MARK: Output folder and cache

    /// The folder as the user knows it: the home folder, or a sandbox container's `Data` folder, becomes `~`.
    /// - Parameter home: the account's home folder. Inside the sandbox `NSHomeDirectory()` is the container, so the
    ///   default reads the account's own.
    public static func displayPath(_ path: String, home: String = accountHome) -> String {
        let homeParts = home.split(separator: "/", omittingEmptySubsequences: false)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard homeParts.count >= 2, parts.starts(with: homeParts) else { return path }
        var rest = parts.dropFirst(homeParts.count)
        if rest.starts(with: ["Library", "Containers"]), let data = rest.dropFirst(3).first, data == "Data",
            rest.count > 4
        {
            rest = rest.dropFirst(4)
        }
        return (["~"] + rest).joined(separator: "/")
    }

    /// The account's home folder from the user database, which the sandbox doesn't redirect.
    public static var accountHome: String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }

    /// "1.43 GB · prepared sources, previews and downloaded inputs", or "Empty".
    public static func cacheSizeText(bytes: Int64) -> String {
        guard bytes > 0 else { return String(localized: "Empty", bundle: .module) }
        return String(
            localized: "\(formatBytes(bytes)) · prepared sources, previews and downloaded inputs", bundle: .module)
    }

    /// Decimal units, as Finder shows them: "820 KB", "12 MB", "1.43 GB"; the number in the locale's digits and
    /// decimal separator. Not `ByteCountFormatStyle`, which writes "kB" and "12.3 MB".
    public static func formatBytes(_ bytes: Int64) -> String {
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < 4 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return String(localized: "\(bytes) bytes", bundle: .module) }
        let number = unit >= 3 ? decimal(value, fractionDigits: 2) : decimal(value.rounded(), fractionDigits: 0)
        return switch unit {
        case 1: String(localized: "\(number) KB", bundle: .module)
        case 2: String(localized: "\(number) MB", bundle: .module)
        case 3: String(localized: "\(number) GB", bundle: .module)
        default: String(localized: "\(number) TB", bundle: .module)
        }
    }

    /// `value` with exactly `fractionDigits` decimals, ungrouped, as `CostText.locale` writes it.
    static func decimal(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never).locale(CostText.locale))
    }
}
