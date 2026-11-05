import CoreGraphics
import Foundation

/// The real-time loop: newest screen frame → OCR → language filtering → translation →
/// floating window (and the in-app live list).
///
/// OCR and translation are two pipelined stages: while one frame is being translated, the next
/// frame is already being read, and each stage always works on the newest data it has.
@MainActor
final class LiveTranslator: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: Int
        var original: String
        var translation: String?
        var sourceName: String
    }

    @Published private(set) var entries: [Entry] = []
    /// Seconds from screen capture to translation on screen, for the last update.
    @Published private(set) var lastLatency: TimeInterval?
    @Published private(set) var lastError: String?
    /// Source languages detected on screen that still need a download.
    @Published private(set) var missingLanguages: [String] = []
    @Published private(set) var isPaused = false

    var settings = AppSettings() {
        didSet { engine.preferHighFidelity = settings.preferHighFidelity }
    }
    var isBroadcasting = false

    let engine = TranslationEngine()
    private let renderer = OverlayRenderer()
    private let floating: FloatingWindowController
    private let catalog: LanguageCatalog

    // OCR stage
    private var ocrRunning = false
    private var ocrAgain = false
    private var forceNextPass = false
    private var lastFrameSequence: UInt64 = 0
    private var unchangedPasses = 0
    private var lastRecognizedKey = ""

    // Translation stage
    private var pendingRecognition: RecognitionResult?
    private var translating = false

    // Output
    private var regionAspect: CGFloat = 16.0 / 9.0
    private var lastNonEmpty = Date.distantPast
    private var items: [OverlayItem] = []
    private var presented: [Candidate] = []

    /// Normalized translations we drew recently. The screen capture also sees the floating
    /// window, so text matching these must not be translated again.
    private var recentOutputKeys: [String] = []
    private var recentOutputSet = Set<String>()

    init(floating: FloatingWindowController, catalog: LanguageCatalog) {
        self.floating = floating
        self.catalog = catalog
    }

    // MARK: - Control

    func frameDidArrive() {
        guard !isPaused else { return }
        if ocrRunning {
            ocrAgain = true
            return
        }
        ocrRunning = true
        Task { await ocrLoop() }
    }

    /// Re-read the latest frame with the current settings (languages, region, …).
    func reprocess() {
        forceNextPass = true
        unchangedPasses = 0
        SignalCenter.shared.post(.requestFreshFrame)
        frameDidArrive()
        refreshOverlay()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { reprocess() } else { refreshOverlay() }
    }

    func clear() {
        entries = []
        items = []
        presented = []
        refreshOverlay()
    }

    private var targetLanguage: Locale.Language? {
        catalog.option(id: settings.targetLanguageID)?.language
    }

    private var sourceLanguage: Locale.Language? {
        catalog.option(id: settings.sourceLanguageID)?.language
    }

    // MARK: - Stage 1: OCR

    private func ocrLoop() async {
        repeat {
            ocrAgain = false
            // When the text on screen hasn't changed for a while (only the background moves),
            // breathe a little between passes to save battery.
            if unchangedPasses >= 6 && !forceNextPass {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if let result = await recognizeLatestFrame() {
                submit(result)
            }
        } while ocrAgain && !isPaused
        ocrRunning = false
    }

    private func recognizeLatestFrame() async -> RecognitionResult? {
        let source = sourceLanguage
        let config = RecognitionConfig(
            languages: source.map(LanguageCatalog.ocrLanguages(for:)) ?? [],
            languageCorrection: settings.languageCorrection,
            smallText: settings.smallText,
            region: settings.regionRect,
            rotation: settings.rotation
        )
        let force = forceNextPass
        forceNextPass = false
        let previousSequence = lastFrameSequence

        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<RecognitionResult?, Error> in
            guard let frame = SharedFrameBuffer.shared?.readLatest() else { return .success(nil) }
            if !force && frame.sequence == previousSequence { return .success(nil) }
            do {
                return .success(try TextRecognizer.recognize(frame, config: config))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .failure(let error):
            lastError = "Text recognition failed: \(error.localizedDescription)"
            return nil
        case .success(nil):
            return nil
        case .success(let result?):
            lastFrameSequence = result.frameSequence
            let key = result.blocks.map(\.text).joined(separator: "\n")
            unchangedPasses = key == lastRecognizedKey ? unchangedPasses + 1 : 0
            lastRecognizedKey = key
            return result
        }
    }

    // MARK: - Stage 2: filter, translate, present

    private func submit(_ result: RecognitionResult) {
        pendingRecognition = result // newer results replace older ones that haven't started yet
        guard !translating else { return }
        translating = true
        Task { await translateLoop() }
    }

    private func translateLoop() async {
        while let next = pendingRecognition {
            pendingRecognition = nil
            await present(next)
        }
        translating = false
    }

    private func present(_ recognition: RecognitionResult) async {
        guard let target = targetLanguage else { return }
        regionAspect = recognition.regionAspect

        var candidates = classify(recognition.blocks, source: sourceLanguage, target: target)
        reuseKnownTranslations(&candidates, target: target)
        let translated = await translate(candidates, to: target)

        if translated.isEmpty && Date().timeIntervalSince(lastNonEmpty) < 2 {
            // Keep the previous lines briefly so dialogue doesn't flicker between frames.
        } else {
            presented = translated
            items = translated.map { OverlayItem(original: $0.block.text, translation: $0.translation, rect: $0.block.rect) }
            entries = translated.enumerated().map { index, item in
                Entry(id: index, original: item.block.text, translation: item.translation,
                      sourceName: displayName(of: item.language))
            }
            if !translated.isEmpty { lastNonEmpty = Date() }
        }
        for item in translated {
            if let translation = item.translation { remember(output: translation) }
        }
        lastLatency = max(0, Date().timeIntervalSince1970 - recognition.frameTimestamp)
        refreshOverlay()
    }

    // MARK: - Filtering

    private struct Candidate {
        var block: TextBlock
        var language: Locale.Language
        var translation: String?
    }

    private func classify(_ blocks: [TextBlock], source: Locale.Language?, target: Locale.Language) -> [Candidate] {
        let targetScripts = LanguageDetector.scripts(for: target)
        let allLanguages = catalog.options.map(\.language)
        var seen = Set<String>()
        var result: [Candidate] = []

        for block in blocks {
            let key = Self.normalized(block.text)
            guard !key.isEmpty, seen.insert(key).inserted, !recentOutputSet.contains(key) else { continue }
            let letters = LanguageDetector.letterCount(in: block.text)
            guard letters > 0 else { continue }

            if let source {
                guard !source.isSameLanguage(as: target), block.confidence >= 0.3,
                      LanguageDetector.text(block.text, isWrittenIn: source) else { continue }
                let sourceScripts = LanguageDetector.scripts(for: source)
                if sourceScripts.contains(.latin) && letters < 2 { continue }
                if !sourceScripts.isDisjoint(with: targetScripts),
                   let detected = LanguageDetector.detect(block.text, candidates: [source, target]),
                   detected.isSameLanguage(as: target) {
                    continue // already in the target language
                }
                result.append(Candidate(block: block, language: source))
            } else {
                guard block.confidence >= 0.45 else { continue }
                if !targetScripts.contains(.latin), LanguageDetector.text(block.text, isWrittenIn: target) { continue }
                guard let detected = LanguageDetector.detect(block.text, candidates: allLanguages),
                      !detected.isSameLanguage(as: target) else { continue }
                if LanguageDetector.scripts(for: detected).contains(.latin) && letters < 2 { continue }
                result.append(Candidate(block: block, language: detected))
            }
        }

        if settings.onlyLongestText, let longest = result.max(by: { $0.block.text.count < $1.block.text.count }) {
            return [longest]
        }
        return result
    }

    /// Fills in translations we already have: exact cache hits, and text that is almost the same
    /// as something on screen a moment ago (OCR often misreads a character or two between frames).
    /// This avoids re-translating — and flickering — on recognition noise.
    private func reuseKnownTranslations(_ candidates: inout [Candidate], target: Locale.Language) {
        for index in candidates.indices {
            let candidate = candidates[index]
            if let cached = engine.cachedTranslation(of: candidate.block.text, from: candidate.language, to: target) {
                candidates[index].translation = cached
                continue
            }
            let text = Self.normalized(candidate.block.text)
            let match = presented.first { previous in
                guard previous.translation != nil, previous.language.isSameLanguage(as: candidate.language) else { return false }
                return Self.similarity(text, Self.normalized(previous.block.text)) >= 0.86
            }
            if let match, let translation = match.translation {
                candidates[index].translation = translation
                engine.remember(translation, for: candidate.block.text, from: candidate.language, to: target)
            }
        }
    }

    private func translate(_ candidates: [Candidate], to target: Locale.Language) async -> [Candidate] {
        var output = candidates
        var needsDownload = Set<String>()
        var missingNames: [String] = []
        let untranslated = candidates.indices.filter { candidates[$0].translation == nil }
        let groups = Dictionary(grouping: untranslated, by: { candidates[$0].language.maximalIdentifier })

        for (languageID, indices) in groups {
            guard let first = indices.first else { continue }
            let source = candidates[first].language
            switch await engine.state(from: source, to: target) {
            case .ready:
                do {
                    let map = try await engine.translate(indices.map { candidates[$0].block.text }, from: source, to: target)
                    for index in indices { output[index].translation = map[candidates[index].block.text] }
                    lastError = nil
                } catch {
                    lastError = "Translation failed: \(error.localizedDescription)"
                }
            case .needsDownload:
                needsDownload.insert(languageID)
                missingNames.append(displayName(of: source))
            case .unsupported:
                break
            }
        }
        missingLanguages = missingNames.sorted()
        // Unsupported pairs are dropped; pairs that still need a download show the original text.
        return output.filter { $0.translation != nil || needsDownload.contains($0.language.maximalIdentifier) }
    }

    private func displayName(of language: Locale.Language) -> String {
        catalog.options.first(where: { $0.language.isSameLanguage(as: language) })?.name ?? language.code
    }

    private func remember(output: String) {
        let key = Self.normalized(output)
        guard !key.isEmpty, recentOutputSet.insert(key).inserted else { return }
        recentOutputKeys.append(key)
        if recentOutputKeys.count > 400 {
            recentOutputSet.remove(recentOutputKeys.removeFirst())
        }
    }

    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }))
    }

    /// 1 − normalized Levenshtein distance, on Unicode scalars.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let longest = max(x.count, y.count)
        // Quick reject when lengths are too different, and cap the work for long paragraphs.
        if Double(abs(x.count - y.count)) / Double(longest) > 0.2 || longest > 400 { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(longest)
    }

    // MARK: - Floating window

    func refreshOverlay() {
        let target = catalog.option(id: settings.targetLanguageID)
        var content = OverlayContent()
        content.items = items
        content.regionAspect = regionAspect
        content.isRightToLeft = target?.isRightToLeft ?? false

        let sourceName = catalog.option(id: settings.sourceLanguageID)?.nativeName ?? "Auto"
        let pair = "\(sourceName) → \(target?.nativeName ?? "?")"
        if isPaused {
            content.status = "❚❚ Paused · \(pair)"
            if items.isEmpty { content.placeholder = "Paused — tap ▶ to resume" }
        } else if !isBroadcasting {
            content.status = "○ Capture off · \(pair)"
            if items.isEmpty { content.placeholder = "Open FloatLingo and tap\n“Start translating”" }
        } else {
            let speed = lastLatency.map { String(format: " · %.1f s", $0) } ?? ""
            content.status = "● Live\(speed) · \(pair)"
            if !missingLanguages.isEmpty {
                content.status = "⬇︎ Download \(missingLanguages.joined(separator: ", ")) in FloatLingo · \(pair)"
            }
            if items.isEmpty { content.placeholder = "Waiting for text to translate…" }
        }

        let style = OverlayStyle(mode: settings.displayMode, theme: settings.theme, shape: settings.windowShape,
                                 fontScale: CGFloat(settings.fontScale), showOriginal: settings.showOriginal)
        if let sampleBuffer = renderer.makeSampleBuffer(content: content, style: style) {
            floating.enqueue(sampleBuffer)
        }
    }

    var previewAspect: CGFloat {
        let size = settings.windowShape.canvasSize(regionAspect: regionAspect)
        return size.width / max(size.height, 1)
    }
}
