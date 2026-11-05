import Foundation
import NaturalLanguage

/// Writing system heuristics plus NaturalLanguage based detection.
enum WritingScript: Hashable {
    case han, kana, hangul, arabic, hebrew, cyrillic, greek, thai, devanagari, latin, other
}

enum LanguageDetector {
    static func script(of scalar: Unicode.Scalar) -> WritingScript? {
        let v = scalar.value
        switch v {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: return .han
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0590...0x05FF: return .hebrew
        case 0x0400...0x052F: return .cyrillic
        case 0x0370...0x03FF: return .greek
        case 0x0E00...0x0E7F: return .thai
        case 0x0900...0x097F: return .devanagari
        default:
            guard scalar.properties.isAlphabetic else { return nil }
            if v < 0x0250 || (0x1E00...0x1EFF).contains(v) { return .latin }
            return .other
        }
    }

    /// Letter counts per writing system.
    static func scriptCounts(in text: String) -> [WritingScript: Int] {
        var counts: [WritingScript: Int] = [:]
        for scalar in text.unicodeScalars {
            if let script = script(of: scalar) { counts[script, default: 0] += 1 }
        }
        return counts
    }

    static func letterCount(in text: String) -> Int {
        scriptCounts(in: text).values.reduce(0, +)
    }

    /// Writing systems a language is written in.
    static func scripts(for language: Locale.Language) -> Set<WritingScript> {
        switch language.code {
        case "zh", "yue": return [.han]
        case "ja": return [.han, .kana]
        case "ko": return [.hangul, .han]
        case "ar", "fa", "ur", "ps", "ug", "ckb", "sd": return [.arabic]
        case "he", "yi": return [.hebrew]
        case "ru", "uk", "bg", "be", "sr", "mk", "kk", "ky", "mn", "tg": return [.cyrillic]
        case "el": return [.greek]
        case "th": return [.thai]
        case "hi", "mr", "ne", "sa": return [.devanagari]
        default: return [.latin]
        }
    }

    /// Whether `text` is mostly written in one of the scripts of `language`.
    static func text(_ text: String, isWrittenIn language: Locale.Language) -> Bool {
        let counts = scriptCounts(in: text)
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return false }
        let matching = scripts(for: language).reduce(0) { $0 + (counts[$1] ?? 0) }
        return Double(matching) / Double(total) >= 0.5
    }

    /// Detects the language of `text`, limited to `candidates` when given.
    static func detect(_ text: String, candidates: [Locale.Language]) -> Locale.Language? {
        let counts = scriptCounts(in: text)
        // Cheap, reliable shortcuts for scripts owned by one language.
        if (counts[.kana] ?? 0) > 0 { return candidates.first { $0.code == "ja" } ?? Locale.Language(identifier: "ja") }
        if (counts[.hangul] ?? 0) > 0 { return candidates.first { $0.code == "ko" } ?? Locale.Language(identifier: "ko") }
        if (counts[.thai] ?? 0) > 0 { return candidates.first { $0.code == "th" } ?? Locale.Language(identifier: "th") }

        let recognizer = NLLanguageRecognizer()
        let constraints = candidates.compactMap(nlLanguage(for:))
        if !constraints.isEmpty { recognizer.languageConstraints = constraints }
        recognizer.processString(text)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        let best = hypothesis.key, confidence = hypothesis.value
        // Very short Latin strings are noisy; demand more confidence.
        let minimum = text.count < 12 && (counts[.latin] ?? 0) > 0 ? 0.6 : 0.3
        guard confidence >= minimum else { return nil }

        let detected = Locale.Language(identifier: best.rawValue)
        return candidates.first { $0.isSameLanguage(as: detected) } ?? (candidates.isEmpty ? detected : nil)
    }

    private static func nlLanguage(for language: Locale.Language) -> NLLanguage? {
        switch language.code {
        case "zh": return language.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese
        default: return NLLanguage(rawValue: language.code)
        }
    }
}
