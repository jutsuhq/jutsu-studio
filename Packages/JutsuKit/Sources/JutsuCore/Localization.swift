#if !canImport(Darwin)
    import Foundation

    // swift-corelibs-foundation has no String(localized:) and SwiftPM copies Localizable.xcstrings unchanged,
    // so on Linux this reads the catalog itself: the same call sites build there, English plurals included. Every
    // module with a catalog (Presentation, HiggsfieldProviders, JobEngine) passes its own `bundle: .module`.
    public struct LinuxLocalizationValue: ExpressibleByStringInterpolation, Sendable {
        public typealias StringInterpolation = LocalizationInterpolation

        var key: String
        var arguments: [LocalizationArgument]

        public init(stringLiteral value: String) {
            key = value
            arguments = []
        }

        public init(stringInterpolation: LocalizationInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }
    }

    extension String {
        public typealias LocalizationValue = LinuxLocalizationValue

        /// `locale` groups integer arguments, as Foundation does on macOS; without it they are written plainly.
        public init(localized value: LocalizationValue, bundle: Bundle, locale: Locale? = nil) {
            let catalog = StringCatalog.cached(for: bundle)
            let template = catalog.englishValue(for: value.key, arguments: value.arguments)
            guard !value.arguments.isEmpty else {
                self = template ?? value.key
                return
            }
            self = StringCatalog.format(template ?? value.key, value.arguments, locale: locale)
        }
    }

    public enum LocalizationArgument: Sendable {
        case int(Int)
        case text(String)
    }

    /// Builds the catalog key the way Foundation does on macOS: "%lld" for integers, "%@" for strings.
    public struct LocalizationInterpolation: StringInterpolationProtocol, Sendable {
        var key = ""
        var arguments: [LocalizationArgument] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation(_ value: some BinaryInteger) {
            key += "%lld"
            arguments.append(.int(Int(value)))
        }

        public mutating func appendInterpolation(_ value: String) {
            key += "%@"
            arguments.append(.text(value))
        }
    }

    private struct CatalogUnit: Decodable, Sendable {
        var value: String
    }

    private struct CatalogLocalization: Decodable, Sendable {
        var stringUnit: CatalogUnit?
        var variations: CatalogVariations?
        var substitutions: [String: CatalogSubstitution]?
    }

    private struct CatalogVariations: Decodable, Sendable {
        var plural: [String: CatalogLocalization]?
    }

    /// A plural inside a sentence, `%#@name@`, picked by the argument at `argNum`.
    private struct CatalogSubstitution: Decodable, Sendable {
        var argNum: Int
        var formatSpecifier: String
        var variations: CatalogVariations
    }

    private struct CatalogEntry: Decodable, Sendable {
        var localizations: [String: CatalogLocalization]?
    }

    /// Each bundle's catalog, read once. Unchecked: `catalogs` is only read and written while holding `lock`.
    private final class CatalogCache: @unchecked Sendable {
        static let shared = CatalogCache()
        private let lock = NSLock()
        private var catalogs: [URL: StringCatalog] = [:]

        func catalog(for bundle: Bundle) -> StringCatalog {
            lock.lock()
            defer { lock.unlock() }
            if let catalog = catalogs[bundle.bundleURL] { return catalog }
            let catalog = StringCatalog.load(from: bundle)
            catalogs[bundle.bundleURL] = catalog
            return catalog
        }
    }

    private struct StringCatalog: Decodable, Sendable {
        var strings: [String: CatalogEntry]

        static func cached(for bundle: Bundle) -> StringCatalog {
            CatalogCache.shared.catalog(for: bundle)
        }

        static func load(from bundle: Bundle) -> StringCatalog {
            guard let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
                let data = try? Data(contentsOf: url),
                let catalog = try? JSONDecoder().decode(StringCatalog.self, from: data)
            else { return StringCatalog(strings: [:]) }
            return catalog
        }

        /// The English template, its plural and substitutions resolved by English rules: "one" for exactly 1,
        /// "other" for everything else.
        func englishValue(for key: String, arguments: [LocalizationArgument]) -> String? {
            guard let english = strings[key]?.localizations?["en"] else { return nil }
            // The argument at `index`, or the first number for a plural of the whole sentence.
            func count(at index: Int?) -> Int? {
                guard let index else {
                    return arguments.lazy.compactMap { if case .int(let n) = $0 { n } else { nil } }.first
                }
                guard arguments.indices.contains(index), case .int(let n) = arguments[index] else { return nil }
                return n
            }
            func variant(_ plural: [String: CatalogLocalization], count: Int?) -> String? {
                (plural[count == 1 ? "one" : "other"] ?? plural["other"])?.stringUnit?.value
            }
            var template: String?
            if let plural = english.variations?.plural {
                template = variant(plural, count: count(at: nil))
            } else {
                template = english.stringUnit?.value
            }
            for (name, substitution) in english.substitutions ?? [:] {
                guard let plural = substitution.variations.plural,
                    let value = variant(plural, count: count(at: substitution.argNum - 1))
                else { continue }
                let positional = "%\(substitution.argNum)$\(substitution.formatSpecifier)"
                template = template?.replacingOccurrences(
                    of: "%#@\(name)@", with: value.replacingOccurrences(of: "%arg", with: positional))
            }
            return template
        }

        /// Fills `%lld`, `%@`, positional `%1$@` and `%%`, the only specifiers the interpolation above produces.
        static func format(_ template: String, _ arguments: [LocalizationArgument], locale: Locale?) -> String {
            var result = ""
            var next = 0
            var characters = template[...]
            while let percent = characters.firstIndex(of: "%") {
                result += characters[..<percent]
                characters = characters[characters.index(after: percent)...]
                if characters.first == "%" {
                    result += "%"
                    characters = characters.dropFirst()
                    continue
                }
                let digits = characters.prefix(while: \.isNumber)
                var index = next
                if let position = Int(digits), characters.dropFirst(digits.count).first == "$" {
                    index = position - 1
                    characters = characters.dropFirst(digits.count + 1)
                } else {
                    next += 1
                }
                characters = characters.drop(while: { $0 == "l" }).dropFirst()
                switch arguments.indices.contains(index) ? arguments[index] : nil {
                case .int(let value): result += locale.map { value.formatted(.number.locale($0)) } ?? String(value)
                case .text(let value): result += value
                case nil: break
                }
            }
            return result + characters
        }
    }
#endif
