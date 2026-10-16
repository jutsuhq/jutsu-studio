import Foundation

/// Text of the About window.
public enum AboutContent {
    public static let disclaimer = String(
        localized: "Unofficial, not affiliated with or endorsed by Higgsfield AI.", bundle: .module)
    public static let license = String(localized: "Released under the MIT License.", bundle: .module)
    public static let fontCredit = String(
        localized: "Barlow Condensed by The Barlow Project Authors, SIL Open Font License 1.1.", bundle: .module)
    public static let updaterCredit = String(
        localized: "Software Update by Sparkle, MIT License.", bundle: .module)
    public static let repository = URL(string: "https://github.com/jutsuhq/jutsu-studio")

    /// "Version 0.1.0 (1)" from the bundle's `CFBundleShortVersionString` and `CFBundleVersion`.
    public static func versionText(info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (version, build) {
        case (let version?, let build?) where version != build:
            return String(localized: "Version \(version) (\(build))", bundle: .module)
        case (let version?, _): return String(localized: "Version \(version)", bundle: .module)
        case (nil, let build?): return String(localized: "Build \(build)", bundle: .module)
        case (nil, nil): return String(localized: "Development build", bundle: .module)
        }
    }
}
