import Foundation
import JutsuCore
import Testing

@testable import Presentation

extension UserDefaultsBackedTests {
    @Suite struct AppSettingsTests {
        func defaults() throws -> UserDefaults {
            let name = "SettingsTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            return defaults
        }

        @Test func emptyDefaultsGiveTheDocumentedValues() throws {
            let defaults = try defaults()
            #expect(AppSettings.defaultResolution(in: defaults) == .p480)
            #expect(AppSettings.maxConcurrency(in: defaults, for: .apiKey) == 2)
            #expect(AppSettings.maxConcurrency(in: defaults, for: .account) == 8)
            #expect(AppSettings.maxConcurrency(in: defaults, for: nil) == 2)
            #expect(AppSettings.spendCap(in: defaults, for: .apiKey) == .usd(75))
            #expect(AppSettings.spendCap(in: defaults, for: .account) == nil)
            #expect(AppSettings.spendCap(in: defaults, for: nil) == nil)
            #expect(AppSettings.notificationPreferences(in: defaults) == NotificationPreferences())
            #expect(AppSettings.outputFolderBookmark(in: defaults) == nil)
            #expect(AppSettings.draftResolution(in: defaults) == .p480)
            #expect(AppSettings.defaultMode(in: defaults) == .motionTransfer)
            #expect(AppSettings.outputNamePattern(in: defaults) == .standard)
        }

        @Test func emptyDefaultsOpenTodaysCreateForm() throws {
            let form = CreateForm(settings: try defaults())
            #expect(form.mode == .motionTransfer)
            #expect(form.resolution == .p480)
            #expect(form.draftTitle == "Draft 480p")
        }

        @Test func everyNameTemplateIsValidAndTheFirstIsTheDefault() {
            #expect(AppSettings.outputNameTemplates.first?.pattern == OutputNamePattern.defaultPattern)
            #expect(AppSettings.outputNameTemplates.allSatisfy { OutputNamePattern.isValid($0.pattern) })
            #expect(Set(AppSettings.outputNameTemplates.map(\.pattern)).count == AppSettings.outputNameTemplates.count)
        }

        @Test func outputNamePatternFallsBackWhenInvalid() throws {
            let defaults = try defaults()
            defaults.set("{res}_{id}", forKey: AppSettings.outputNamePatternKey)
            #expect(AppSettings.outputNamePattern(in: defaults).pattern == "{res}_{id}")
            defaults.set("{resolution}", forKey: AppSettings.outputNamePatternKey)
            #expect(AppSettings.outputNamePattern(in: defaults) == .standard)
        }

        @Test func outputNameExampleIsAClaymationRestyle() throws {
            let utc = try #require(TimeZone(identifier: "UTC"))
            let date = Date(timeIntervalSince1970: 1_760_356_800)  // 2025-10-13 12:00 UTC
            #expect(
                AppSettings.outputNameExample("{preset} {res} {time}", date: date, timeZone: utc)
                    == "Claymation 720p 12-00-00.mp4")
            #expect(AppSettings.outputNameExample("", date: date, timeZone: utc) == "2025-10-13_restyle_1a2b3c4d.mp4")
        }

        @Test func storedValuesAreRead() throws {
            let defaults = try defaults()
            defaults.set("1080p", forKey: AppSettings.defaultResolutionKey)
            defaults.set(42.5, forKey: AppSettings.spendCapUSDKey)
            defaults.set(false, forKey: AppSettings.notifyOnDoneKey)
            defaults.set(false, forKey: AppSettings.notificationSoundKey)
            defaults.set(Data([1, 2]), forKey: AppSettings.outputFolderBookmarkKey)
            defaults.set("720p", forKey: AppSettings.draftResolutionKey)
            defaults.set("restyle", forKey: AppSettings.defaultModeKey)
            #expect(AppSettings.defaultResolution(in: defaults) == .p1080)
            let cap = try #require(Decimal(string: "42.5"))
            #expect(AppSettings.spendCap(in: defaults, for: .apiKey) == .usd(cap))
            #expect(
                AppSettings.notificationPreferences(in: defaults)
                    == NotificationPreferences(onDone: false, onProblems: true, playsSound: false))
            #expect(AppSettings.outputFolderBookmark(in: defaults) == Data([1, 2]))
            #expect(AppSettings.draftResolution(in: defaults) == .p720)
            #expect(AppSettings.defaultMode(in: defaults) == .restyle)
            let form = CreateForm(settings: defaults)
            #expect(form.mode == .restyle)
            #expect(form.draftTitle == "Draft 720p")
        }

        @Test func unknownValuesFallBackToTheDefaults() throws {
            let defaults = try defaults()
            defaults.set("4k", forKey: AppSettings.defaultResolutionKey)
            defaults.set("4k", forKey: AppSettings.draftResolutionKey)
            defaults.set("dance", forKey: AppSettings.defaultModeKey)
            #expect(AppSettings.defaultResolution(in: defaults) == .p480)
            #expect(AppSettings.draftResolution(in: defaults) == .p480)
            #expect(AppSettings.defaultMode(in: defaults) == .motionTransfer)
        }

        @Test func disabledCapIsNil() throws {
            let defaults = try defaults()
            defaults.set(false, forKey: AppSettings.spendCapEnabledKey)
            #expect(AppSettings.spendCap(in: defaults, for: .apiKey) == nil)
            defaults.set(true, forKey: AppSettings.spendCapEnabledKey)
            defaults.set(-3.0, forKey: AppSettings.spendCapUSDKey)
            #expect(AppSettings.spendCap(in: defaults, for: .apiKey) == .usd(75))
        }

        @Test func accountCapIsInCredits() throws {
            let defaults = try defaults()
            defaults.set(true, forKey: AppSettings.spendCapCreditsEnabledKey)
            #expect(AppSettings.spendCap(in: defaults, for: .account) == .credits(1_000))
            defaults.set(250, forKey: AppSettings.spendCapCreditsKey)
            #expect(AppSettings.spendCap(in: defaults, for: .account) == .credits(250))
            defaults.set(0, forKey: AppSettings.spendCapCreditsKey)
            #expect(AppSettings.spendCap(in: defaults, for: .account) == .credits(1_000))
            defaults.set(false, forKey: AppSettings.spendCapEnabledKey)
            #expect(AppSettings.spendCap(in: defaults, for: .account) == .credits(1_000))
        }

        @Test func turningOffTheOldNotifySwitchKeepsProblemsQuiet() throws {
            let defaults = try defaults()
            defaults.set(false, forKey: AppSettings.notifyOnDoneKey)
            AppSettings.migrate(defaults)
            #expect(AppSettings.notificationPreferences(in: defaults) == NotificationPreferences.off)
            defaults.set(true, forKey: AppSettings.notifyOnProblemsKey)
            AppSettings.migrate(defaults)
            #expect(AppSettings.notificationPreferences(in: defaults).onProblems)
        }

        @Test func migratingFreshDefaultsWritesNothing() throws {
            let defaults = try defaults()
            AppSettings.migrate(defaults)
            #expect(defaults.object(forKey: AppSettings.notifyOnProblemsKey) == nil)
        }

        @Test(arguments: [("1000", 1_000), ("1,000", 1_000), (" 1 000 cr", 1_000), ("250 Credits", 250)])
        func capCreditsParse(text: String, expected: Int) {
            #expect(AppSettings.parseCapCredits(text) == expected)
        }

        @Test(arguments: ["", "cr", "abc", "-5", "0", "1.5", "1e3", "$100"])
        func invalidCapCreditsAreNil(text: String) {
            #expect(AppSettings.parseCapCredits(text) == nil)
        }

        @Test func creditsFormatting() {
            CostText.$locale.withValue(.enUS) {
                #expect(AppSettings.formatCredits(1_000, locale: .enUS) == "1,000 credits")
                #expect(AppSettings.formatCredits(1, locale: .enUS) == "1 credit")
                #expect(AppSettings.formatSpend(1_250, unit: .credits, locale: .enUS) == "1,250 credits")
                #expect(AppSettings.formatSpend(12.5, unit: .usd, locale: .enUS) == "$12.50")
            }
        }

        @Test func loginItemSwitch() {
            #expect(LoginItemStatus.enabled.isOn)
            #expect(LoginItemStatus.requiresApproval.isOn)
            #expect(!LoginItemStatus.disabled.isOn)
            #expect(LoginItemStatus.enabled.note == nil)
            #expect(LoginItemStatus.requiresApproval.note?.contains("Login Items") == true)
        }

        @Test(arguments: [(-5, 1), (0, 1), (1, 1), (2, 2), (40, 40), (41, 40), (1_000, 40)])
        func concurrencyIsClamped(value: Int, expected: Int) throws {
            let defaults = try defaults()
            defaults.set(value, forKey: AppSettings.maxConcurrencyKey)
            #expect(AppSettings.maxConcurrency(in: defaults, for: .account) == expected)
            #expect(AppSettings.maxConcurrency(stored: value, for: .apiKey) == expected)
        }

        @Test func aSetLimitWinsOverTheConnectionsDefault() throws {
            #expect(AppSettings.maxConcurrency(stored: nil, for: .account) == 8)
            #expect(AppSettings.maxConcurrency(stored: nil, for: .apiKey) == 2)
            #expect(AppSettings.maxConcurrency(stored: 3, for: .account) == 3)
        }

        @Test(arguments: [
            ("75", 75.0), ("$75.00", 75.0), (" $ 1,000.5 ", 1_000.5), ("12.346", 12.35), (".5", 0.5),
        ])
        func capAmountParses(text: String, expected: Double) {
            #expect(AppSettings.parseCapAmount(text) == expected)
        }

        @Test(arguments: ["", "$", "abc", "-5", "0", "$0.00", "1e3", "7.5.1", "inf", "75 USD", "99999999999999999999"])
        func invalidCapAmountIsNil(text: String) {
            #expect(AppSettings.parseCapAmount(text) == nil)
        }

        /// A cap stored before the upper bound is read without trapping.
        @Test func aHugeStoredCapIsRead() throws {
            let defaults = try #require(UserDefaults(suiteName: "SettingsTests-\(UUID())"))
            defaults.set(1e30, forKey: AppSettings.spendCapUSDKey)
            #expect(AppSettings.spendCap(in: defaults, for: .apiKey) == .usd(Decimal(1e30)))
        }

        @Test func usdFormatting() {
            CostText.$locale.withValue(.enUS) {
                #expect(AppSettings.formatUSD(75.0) == "$75.00")
                #expect(AppSettings.formatUSD(Decimal(string: "12.5")!) == "$12.50")
                #expect(AppSettings.parseCapAmount(AppSettings.formatUSD(19.99)) == 19.99)
            }
        }

        @Test func cacheSizeText() {
            CostText.$locale.withValue(.enUS) {
                #expect(AppSettings.cacheSizeText(bytes: 0) == "Empty")
                #expect(
                    AppSettings.cacheSizeText(bytes: 1_430_000_000)
                        == "1.43 GB · prepared sources, previews and downloaded inputs")
                #expect(AppSettings.formatBytes(512) == "512 bytes")
                #expect(AppSettings.formatBytes(820_400) == "820 KB")
                #expect(AppSettings.formatBytes(12_300_000) == "12 MB")
                #expect(AppSettings.formatBytes(2_500_000_000_000) == "2.50 TB")
            }
        }

        @Test(arguments: [
            ("/Users/me/Movies/Jutsu Studio", "~/Movies/Jutsu Studio"),
            ("/Users/me/Library/Containers/com.jutsustudio/Data/Movies/Jutsu Studio", "~/Movies/Jutsu Studio"),
            ("/Users/me/Library/Preferences", "~/Library/Preferences"),
            ("/Volumes/Media/Renders", "/Volumes/Media/Renders"),
            ("/Users/me", "~"),
        ])
        func displayPath(path: String, expected: String) {
            #expect(AppSettings.displayPath(path) == expected)
        }
    }
}

@Suite struct ConnectionCardTests {
    let someModes = Capabilities(
        modes: [.objectSwap, .motionTransfer], resolutions: [.p480], costUnit: .credits, maxConcurrency: nil)

    @Test func notConnectedHasNoRows() {
        #expect(ConnectionState.none.cardRows(capabilities: nil).isEmpty)
    }

    @Test func apiKeyIsMaskedAndKeptInKeychain() {
        let rows = ConnectionState.apiKey(keyID: "hf_live_1234567890abcd").cardRows(capabilities: someModes)
        #expect(rows.map(\.label) == ["Key ID", "Secret", "Stored in"])
        #expect(rows[0].value == "hf_l…abcd")
        #expect(rows[0].isMonospaced)
        #expect(!rows[1].value.contains("1234"))
        #expect(rows[2].value == "macOS Keychain")
    }

    @Test func shortKeyIDIsShownAsIs() {
        #expect(ConnectionState.apiKey(keyID: "kid-1").cardRows(capabilities: nil).first?.value == "kid-1")
    }

    @Test func accountShowsWhatIsKnown() {
        let info = AccountInfo(email: "me@example.com", plan: "Creator", credits: 1_200)
        let rows = ConnectionState.account(info).cardRows(
            capabilities: someModes, locale: Locale(identifier: "en_US"))
        #expect(rows.map(\.label) == ["Account", "Plan", "Credits", "Genjutsu"])
        #expect(rows.map(\.value) == ["me@example.com", "Creator", "1,200", "Motion transfer · Object swap"])
    }

    @Test func accountBeforeTheFirstProviderCall() {
        let rows = ConnectionState.account(AccountInfo()).cardRows(capabilities: nil)
        #expect(rows.map(\.label) == ["Account", "Genjutsu"])
        #expect(rows.map(\.value) == ["Signed in", "Checking…"])
        let none = Capabilities(modes: [], resolutions: [], costUnit: .credits, maxConcurrency: nil)
        #expect(ConnectionState.account(AccountInfo()).cardRows(capabilities: none).last?.value == "None")
    }
}

@Suite struct DailySpendTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let noon = Date(timeIntervalSince1970: 1_760_356_800)  // 2025-10-13 12:00 UTC

    func job(_ state: JobState, cost: Cost, finishedAt: Date? = nil) -> Job {
        let source = SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 10,
            pixelSize: PixelSize(width: 1280, height: 720), range: 0...10)
        let spec = JobSpec(mode: .motionTransfer, source: source, references: [], resolution: .p480)
        var job = Job(spec: spec, providerKind: .apiKey, cost: cost)
        job.state = state
        job.finishedAt = finishedAt
        return job
    }

    @Test func countsTodaysFinishedAndEveryActiveJob() {
        let jobs = [
            job(.done, cost: .usd(10, isEstimate: false), finishedAt: noon),
            job(.done, cost: .usd(100, isEstimate: false), finishedAt: noon - 86_400),
            job(.queued, cost: .usd(Decimal(string: "2.5")!, isEstimate: true)),
            job(.paused(.insufficientFunds), cost: .usd(1, isEstimate: true)),
            job(.failed(reason: .message("x")), cost: .usd(50, isEstimate: false), finishedAt: noon),
            job(.canceled, cost: .usd(50, isEstimate: false), finishedAt: noon),
            job(.processing, cost: .credits(500, isEstimate: true)),
        ]
        #expect(DailySpend.committed(jobs, on: noon, calendar: calendar) == Decimal(string: "13.5"))
    }

    @Test func countsAChargedJobWhoseDownloadFailed() {
        var failed = job(.failed(reason: .message("download")), cost: .usd(3, isEstimate: false), finishedAt: noon)
        failed.chargedAt = noon
        let done = job(.done, cost: .usd(10, isEstimate: false), finishedAt: noon)
        #expect(DailySpend.committed([failed, done], on: noon, calendar: calendar) == 13)
    }

    @Test func countsAChargedJobWhoseDownloadWasCanceled() {
        var canceled = job(.canceled, cost: .usd(7, isEstimate: false), finishedAt: noon)
        canceled.chargedAt = noon
        let queued = job(.queued, cost: .usd(2, isEstimate: true))
        #expect(DailySpend.committed([canceled, queued], on: noon, calendar: calendar) == 9)
    }

    @Test func chargedDownloadFailuresFromAnotherDayDontCount() {
        var failed = job(
            .failed(reason: .message("download")), cost: .usd(3, isEstimate: false), finishedAt: noon - 86_400)
        failed.chargedAt = noon - 86_400
        #expect(DailySpend.committed([failed], on: noon, calendar: calendar) == 0)
    }

    @Test func nothingCommittedIsZero() {
        #expect(DailySpend.committed([], on: noon, calendar: calendar) == 0)
    }

    @Test func eachUnitIsCountedApart() {
        let jobs = [
            job(.done, cost: .credits(120, isEstimate: true), finishedAt: noon),
            job(.queued, cost: .credits(30, isEstimate: true)),
            job(.done, cost: .usd(10, isEstimate: false), finishedAt: noon),
        ]
        #expect(DailySpend.committed(jobs, on: noon, in: .credits, calendar: calendar) == 150)
        #expect(DailySpend.committed(jobs, on: noon, in: .usd, calendar: calendar) == 10)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CacheSizeTests {
    @Test func sumsFilesInEveryFolderAndIgnoresMissingOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheSizeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources")
        let presets = root.appendingPathComponent("cache/presets")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: presets, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: sources.appendingPathComponent("a.mp4"))
        try Data(count: 234).write(to: presets.appendingPathComponent("b.jpg"))

        let total = await CacheSize.bytes(in: [
            sources, root.appendingPathComponent("cache"), root.appendingPathComponent("missing"),
        ])
        #expect(total == 1_234)
    }
}
