import CoreGraphics
import Foundation

/// The real-time loop: newest screen frame → OCR → language filtering → translation →
/// floating window (and the in-app live list).
@MainActor
final class LiveTranslator: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: Int
        var original: String
        var translation: String?
        var sourceName: String
    }

    @Published private(set) var entries: [Entry] = []
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

    private var isRunning = false
    private var needsAnotherPass = false
    private var forceNextPass = false
    private var lastFrameTimestamp: Double = 0
    private var regionAspect: CGFloat = 16.0 / 9.0
    private var lastNonEmpty = Date.distantPast
    private var items: [OverlayItem] = []

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
        if isRunning {
            needsAnotherPass = true
            return
        }
        isRunning = true
        Task { await runLoop() }
    }

    /// Re-read the latest frame with the current settings (languages, region, …).
    func reprocess() {
        forceNextPass = true
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
        refreshOverlay()
    }

    // MARK: - Loop

    private func runLoop() async {
        repeat {
            needsAnotherPass = false
            await processLatestFrame()
        } while needsAnotherPass && !isPaused
        isRunning = false
    }

    private var targetLanguage: Locale.Language? {
        catalog.option(id: settings.targetLanguageID)?.language
    }

    private var sourceLanguage: Locale.Language? {
        catalog.option(id: settings.sourceLanguageID)?.language
    }

    private func processLatestFrame() async {
        guard let target = targetLanguage else { return }
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
        let previousTimestamp = lastFrameTimestamp

        let outcome: Result<RecognitionResult?, Error> = await Task.detached(priority: .userInitiated) {
            guard let frame = FrameFile.read() else { return .success(nil) }
            if !force && frame.timestamp == previousTimestamp { return .success(nil) }
            do {
                return .success(try TextRecognizer.recognize(frame, config: config))
            } catch {
                return .failure(error)
            }
        }.value

        let recognition: RecognitionResult
        switch outcome {
        case .failure(let error):
            lastError = "Text recognition failed: \(error.localizedDescription)"
            return
        case .success(nil):
            return
        case .success(let value?):
            recognition = value
        }

        let started = Date()
        lastFrameTimestamp = recognition.frameTimestamp
        regionAspect = recognition.regionAspect

        let candidates = classify(recognition.blocks, source: source, target: target)
        let translated = await translate(candidates, to: target)

        if translated.isEmpty && Date().timeIntervalSince(lastNonEmpty) < 4 && !force {
            // Keep the previous lines briefly so dialogue doesn't flicker between frames.
        } else {
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
        lastLatency = recognition.duration + Date().timeIntervalSince(started)
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

    private func translate(_ candidates: [Candidate], to target: Locale.Language) async -> [Candidate] {
        var output = candidates
        var needsDownload = Set<String>()
        var missingNames: [String] = []
        let groups = Dictionary(grouping: candidates.indices, by: { candidates[$0].language.maximalIdentifier })

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
            if items.isEmpty { content.placeholder = "Open FloatLingo and tap\n“Start screen capture”" }
        } else {
            content.status = "● Live · \(pair)"
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
