import Foundation

/// Only application-authored interface text belongs here. Recorded evidence never passes through this API.
enum LensL10n {
    enum Language: String, CaseIterable, Identifiable {
        case system, fr, en
        var id: String { rawValue }
    }

    /// Synchronous lookup is also used by pure labels/default arguments. Only the mutable language is locked.
    private final class LanguageState: @unchecked Sendable {
        private let lock = NSLock()
        private var selected = Language(rawValue: UserDefaults.standard.string(forKey: "lens.language") ?? "system") ?? .system
        var language: Language {
            get { lock.lock(); defer { lock.unlock() }; return selected }
            set { lock.lock(); defer { lock.unlock() }; selected = newValue }
        }
    }
    private static let languageState = LanguageState()
    /// The root view synchronizes this value with AppStorage without replacing stores or view identities.
    static var language: Language {
        get { languageState.language }
        set { languageState.language = newValue }
    }
    static var resolvedLanguage: Language {
        let selected = language
        if selected != .system { return selected }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("fr") == true ? .fr : .en
    }

    private struct Catalogue: Decodable {
        let schemaVersion: Int
        let language: String
        let translations: [String: String]
    }
    private struct Pattern {
        let prefix: String
        let literalLength: Int
        let key: String
        let placeholders: [String]
        let expression: NSRegularExpression
    }

    /// Read once from the app bundle. This catalogue contains UI text, never authentication or session data.
    private static let translations: [String: String] = {
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: "en", withExtension: "json", subdirectory: "Localizations") { urls.append(url) }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        urls.append(root.appendingPathComponent("Assets/Localizations/en.json"))
        #endif
        for url in urls {
            guard let data = try? Data(contentsOf: url), data.count <= 2_000_000,
                  let catalogue = try? JSONDecoder().decode(Catalogue.self, from: data),
                  catalogue.schemaVersion == 1, catalogue.language == "en", catalogue.translations.count <= 10_000 else { continue }
            return catalogue.translations.filter { placeholders(in: $0.key) == placeholders(in: $0.value) }
        }
        return [:] // The visible French source remains intact if a bundle resource is missing.
    }()
    static var catalogueEntryCount: Int { translations.count }

    private static let placeholderExpression = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    private static func placeholders(in text: String) -> Set<String> {
        let source = text as NSString
        return Set(placeholderExpression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range(at: 1)) })
    }
    private static func substitute(_ template: String, values: [String: String]) -> String {
        let source = template as NSString
        var result = template
        for match in placeholderExpression.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            let identifier = source.substring(with: match.range(at: 1))
            guard let value = values[identifier], let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
    /// For controls rebuilt during a language change, use the binding's new
    /// value directly instead of waiting for the root's synchronization callback.
    static func text(_ french: String, in language: Language) -> String {
        let english = language == .en || (language == .system && Locale.preferredLanguages.first?.lowercased().hasPrefix("fr") != true)
        return english ? translations[french] ?? french : french
    }

    static func text(_ french: String, _ values: String...) -> String {
        let template = resolvedLanguage == .en ? translations[french] ?? french : french
        return substitute(template, values: Dictionary(uniqueKeysWithValues: values.enumerated().map { (String($0.offset), $0.element) }))
    }

    private static func makePatterns(_ templates: [String]) -> [Pattern] {
        templates.compactMap { key -> Pattern? in
            let source = key as NSString
            let matches = placeholderExpression.matches(in: key, range: NSRange(location: 0, length: source.length))
            guard let first = matches.first, first.range.location > 0 else { return nil }
            var expression = "^", offset = 0, identifiers: [String] = []
            for match in matches {
                expression += NSRegularExpression.escapedPattern(for: source.substring(with: NSRange(location: offset, length: match.range.location - offset))) + "(.*?)"
                identifiers.append(source.substring(with: match.range(at: 1))); offset = NSMaxRange(match.range)
            }
            expression += NSRegularExpression.escapedPattern(for: source.substring(from: offset)) + "$"
            guard let regex = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]) else { return nil }
            return Pattern(prefix: source.substring(to: first.range.location), literalLength: source.length - matches.reduce(0) { $0 + $1.range.length }, key: key, placeholders: identifiers, expression: regex)
        }.sorted {
            if $0.prefix.count != $1.prefix.count { return $0.prefix.count > $1.prefix.count }
            // A generic "Session {0}" must not shadow a specific missing-session
            // notice with the same prefix. Recorded/user text is never routed here.
            if $0.literalLength != $1.literalLength { return $0.literalLength > $1.literalLength }
            return $0.key < $1.key
        }
    }
    private static let patterns = makePatterns(Array(translations.keys))
    /// Stored UI notices can outlive a language change. Reverse only unambiguous registered English text.
    private static let reverseTranslations: [String: String] = {
        var candidates: [String: String] = [:], ambiguous = Set<String>()
        for (french, english) in translations {
            if let existing = candidates[english], existing != french { ambiguous.insert(english) }
            else { candidates[english] = french }
        }
        return candidates.filter { !ambiguous.contains($0.key) }
    }()
    private static let reversePatterns = makePatterns(Array(reverseTranslations.keys))

    /// Resolve a known UI label/message produced outside SwiftUI. Callers must classify their source.
    /// Matching is limited to catalogue entries; arbitrary recorded messages and user questions stay verbatim.
    static func display(_ knownUI: String) -> String {
        let english = resolvedLanguage == .en
        let catalogue = english ? translations : reverseTranslations
        if let exact = catalogue[knownUI] { return exact }
        let source = knownUI as NSString
        for pattern in english ? patterns : reversePatterns where knownUI.hasPrefix(pattern.prefix) {
            guard let match = pattern.expression.firstMatch(in: knownUI, range: NSRange(location: 0, length: source.length)) else { continue }
            var values: [String: String] = [:], consistent = true
            for (index, identifier) in pattern.placeholders.enumerated() {
                let value = source.substring(with: match.range(at: index + 1))
                if let previous = values[identifier], previous != value { consistent = false; break }
                values[identifier] = value
            }
            if consistent, let translated = catalogue[pattern.key] { return substitute(translated, values: values) }
        }
        return knownUI
    }
}

extension Date {
    /// UI formatting only; the stored instant and captured evidence content do not change.
    func lensFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(Locale(identifier: LensL10n.resolvedLanguage.rawValue)))
    }
}
