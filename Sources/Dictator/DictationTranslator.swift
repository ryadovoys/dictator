import Foundation
import NaturalLanguage
import Translation

/// Translates a dictation into the language chosen with /translate, on this Mac, with Apple
/// Translation. Translating without a window needs macOS 26. Anything it cannot do leaves the
/// dictation as spoken and says why in `note`, so a wrong language never reaches the field silently.
enum DictationTranslator {
    struct Language: Equatable {
        let code: String
        let name: String
    }

    struct Outcome: Equatable {
        let text: String
        /// What was said, when `text` is a translation of it.
        let original: String?
        /// For the terminal's history: "from Russian", or why the text was not translated.
        let note: String?
    }

    static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// English names, like the rest of the interface: "Spanish", "Chinese (Traditional)".
    static func name(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
    }

    /// Every language Apple Translation can translate into, sorted by name.
    static func languages() async -> [Language] {
        guard isAvailable else { return [] }
        let codes = Set(await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier))
        return codes.map { Language(code: $0, name: name($0)) }.sorted { $0.name < $1.name }
    }

    /// "es", "spanish" or "span" → Spanish. Exact code or name first, then a name prefix.
    static func match(_ query: String, in languages: [Language]) -> Language? {
        let query = query.lowercased()
        return languages.first { $0.code.lowercased() == query || $0.name.lowercased() == query }
            ?? languages.first { $0.name.lowercased().hasPrefix(query) }
    }

    static func translate(_ text: String, to target: String) async -> Outcome {
        let unchanged = { (note: String?) in Outcome(text: text, original: nil, note: note) }
        guard #available(macOS 26, *) else { return unchanged("not translated, needs macOS 26") }
        guard let spoken = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue else {
            return unchanged("not translated, language not recognized")
        }
        let source = Locale.Language(identifier: spoken), destination = Locale.Language(identifier: target)
        // Already in the chosen language: nothing to do and nothing worth mentioning.
        if source.languageCode == destination.languageCode { return unchanged(nil) }
        switch await LanguageAvailability().status(from: source, to: destination) {
        case .installed: break
        case .supported:
            // A terminal app cannot show the download sheet; System Settings can.
            return unchanged("not translated, download \(name(spoken)) and \(name(target)) in System Settings → "
                + "General → Language & Region → Translation Languages")
        default:
            return unchanged("not translated, \(name(spoken)) to \(name(target)) is not available")
        }
        // The first request after launch can fail while the translation model loads.
        for _ in 0..<3 {
            if let response = try? await TranslationSession(installedSource: source, target: destination).translate(text) {
                return Outcome(text: response.targetText, original: text, note: "from \(name(spoken))")
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return unchanged("not translated, translation failed")
    }
}
