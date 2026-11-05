import Foundation
import Translation

/// On-device translation with one `TranslationSession` per language pair and a string cache,
/// so text that stays on screen (menus, names, buttons) is translated only once.
@MainActor
final class TranslationEngine {
    enum PairState: Equatable {
        case ready
        case needsDownload
        case unsupported
    }

    var preferHighFidelity = false {
        didSet { if oldValue != preferHighFidelity { sessions.removeAll() } }
    }

    private var sessions: [String: TranslationSession] = [:]
    private var pairStates: [String: PairState] = [:]
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 3000
    private let availability = LanguageAvailability()

    private func key(_ source: Locale.Language, _ target: Locale.Language) -> String {
        source.maximalIdentifier + ">" + target.maximalIdentifier
    }

    /// Forget cached availability (call after the user downloads languages).
    func refreshAvailability() {
        pairStates.removeAll()
        sessions.removeAll()
    }

    func state(from source: Locale.Language, to target: Locale.Language) async -> PairState {
        let pair = key(source, target)
        if let known = pairStates[pair] { return known }
        let status = await availability.status(from: source, to: target)
        let state: PairState
        switch status {
        case .installed: state = .ready
        case .supported: state = .needsDownload
        case .unsupported: state = .unsupported
        @unknown default: state = .unsupported
        }
        pairStates[pair] = state
        return state
    }

    /// Cache keys ignore whitespace differences, which OCR produces a lot of.
    private func cacheKey(_ text: String, _ pair: String) -> String {
        pair + "|" + text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func cachedTranslation(of text: String, from source: Locale.Language, to target: Locale.Language) -> String? {
        cache[cacheKey(text, key(source, target))]
    }

    /// Records a translation obtained some other way (e.g. reused for a near-identical OCR result).
    func remember(_ translation: String, for text: String, from source: Locale.Language, to target: Locale.Language) {
        store(translation, for: cacheKey(text, key(source, target)))
    }

    /// Translates `texts` (all in `source`), returning `[original: translation]`.
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String: String] {
        let pair = key(source, target)
        var result: [String: String] = [:]
        var missing: [String] = []
        for text in Set(texts) {
            if let hit = cache[cacheKey(text, pair)] { result[text] = hit } else { missing.append(text) }
        }
        guard !missing.isEmpty else { return result }

        let session = try makeSession(source: source, target: target)
        let requests = missing.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        do {
            let responses = try await session.translations(from: requests)
            for response in responses {
                guard let id = response.clientIdentifier, let index = Int(id), missing.indices.contains(index) else { continue }
                let original = missing[index]
                result[original] = response.targetText
                store(response.targetText, for: cacheKey(original, pair))
            }
        } catch {
            // A broken session (e.g. languages removed in Settings) is rebuilt next time.
            sessions[pair] = nil
            pairStates[pair] = nil
            throw error
        }
        return result
    }

    private func makeSession(source: Locale.Language, target: Locale.Language) throws -> TranslationSession {
        let pair = key(source, target)
        if let existing = sessions[pair] { return existing }
        let session: TranslationSession
        if #available(iOS 26.4, *), preferHighFidelity {
            session = try TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity)
        } else {
            session = try TranslationSession(installedSource: source, target: target)
        }
        sessions[pair] = session
        return session
    }

    private func store(_ translation: String, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = translation
        if cacheOrder.count > cacheLimit {
            let overflow = cacheOrder.count - cacheLimit
            cacheOrder.prefix(overflow).forEach { cache[$0] = nil }
            cacheOrder.removeFirst(overflow)
        }
    }
}
