import Foundation
import Translation
import Vision

struct LanguageOption: Identifiable, Hashable {
    /// `Locale.Language.maximalIdentifier`, e.g. "zh-Hans-CN", "ar-Arab-SA".
    let id: String
    let language: Locale.Language
    /// Name in the user's UI language, e.g. "Chinese (Simplified)".
    let name: String
    /// Name in the language itself, e.g. "العربية".
    let nativeName: String

    var isRightToLeft: Bool { language.isRightToLeft }
}

extension Locale.Language {
    var code: String { languageCode?.identifier ?? minimalIdentifier }

    var isRightToLeft: Bool {
        ["ar", "he", "fa", "ur", "ps", "yi", "dv", "ug", "ckb", "sd"].contains(code)
    }

    /// Two languages are "the same" for our purposes when language and script match
    /// (en-US == en-GB, but zh-Hans != zh-Hant).
    func isSameLanguage(as other: Locale.Language) -> Bool {
        guard code == other.code else { return false }
        if code == "zh" { return (script?.identifier ?? "Hans") == (other.script?.identifier ?? "Hans") }
        return true
    }
}

/// The languages the on-device Translation framework supports, plus mapping to Vision OCR.
@MainActor
final class LanguageCatalog: ObservableObject {
    @Published private(set) var options: [LanguageOption] = []
    @Published private(set) var isLoaded = false

    /// Languages Vision's accurate text recognizer can read, e.g. ["en-US", "zh-Hans", "ar-SA", …].
    nonisolated static let supportedOCRLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }()

    func load() async {
        let languages = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        var unique: [Locale.Language] = []
        for language in languages where seen.insert(language.maximalIdentifier).inserted {
            unique.append(language)
        }

        let current = Locale.current
        let codeCounts = Dictionary(grouping: unique, by: \.code).mapValues(\.count)
        options = unique.map { language in
            let code = language.code
            var name = current.localizedString(forLanguageCode: code) ?? language.maximalIdentifier
            if (codeCounts[code] ?? 0) > 1 {
                if code == "zh", let script = language.script?.identifier {
                    name = current.localizedString(forIdentifier: "zh-" + script)
                        ?? name + " (" + (current.localizedString(forScriptCode: script) ?? script) + ")"
                } else if let region = language.region?.identifier {
                    name += " (" + (current.localizedString(forRegionCode: region) ?? region) + ")"
                }
            }
            let native = Locale(identifier: language.maximalIdentifier).localizedString(forLanguageCode: code) ?? name
            return LanguageOption(id: language.maximalIdentifier, language: language, name: name.capitalized(with: current), nativeName: native)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        isLoaded = true
    }

    func option(id: String?) -> LanguageOption? {
        guard let id else { return nil }
        return options.first { $0.id == id }
    }

    /// The best target language for a fresh install: the device language when supported.
    func defaultTargetID() -> String? {
        for identifier in Locale.preferredLanguages {
            let preferred = Locale.Language(identifier: identifier)
            if let match = options.first(where: { $0.language.isSameLanguage(as: preferred) }) {
                return match.id
            }
        }
        return options.first { $0.language.code == "en" }?.id ?? options.first?.id
    }

    /// Vision recognition language codes for a translation source language.
    nonisolated static func ocrLanguages(for language: Locale.Language) -> [String] {
        let code = language.code
        let supported = supportedOCRLanguages
        var result: [String] = []
        if code == "zh" {
            let script = language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
            result = supported.filter { $0 == script }
        } else {
            result = supported.filter { $0 == code || $0.hasPrefix(code + "-") }
        }
        // English UI labels are common in every app, keep them readable too.
        if code != "en", let english = supported.first(where: { $0.hasPrefix("en") }) {
            result.append(english)
        }
        return result
    }
}
