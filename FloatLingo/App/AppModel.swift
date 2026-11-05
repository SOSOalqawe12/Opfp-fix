import Foundation
import ReplayKit
import SwiftUI
import Translation

/// App-wide state: settings, capture status, language downloads.
@MainActor
final class AppModel: ObservableObject {
    enum PairStatus: Equatable {
        case unknown
        case ready
        case needsDownload
        case unsupported
        case sameLanguage
        /// Auto-detect: how many source languages are downloaded for the chosen target.
        case autoDetect(installed: Int, total: Int)
    }

    @Published var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var isBroadcasting = false
    @Published private(set) var pairStatus: PairStatus = .unknown
    /// Download state of every source language → current target, keyed by language id.
    @Published private(set) var sourceStates: [String: TranslationEngine.PairState] = [:]
    @Published var downloadConfiguration: TranslationSession.Configuration?
    @Published private(set) var downloadError: String?

    let catalog: LanguageCatalog
    let floating: FloatingWindowController
    let translator: LiveTranslator
    let broadcast = BroadcastLauncher()

    private var timer: Timer?
    private var tickCount = 0
    private var didStart = false

    init() {
        let settings = AppSettings.load()
        let catalog = LanguageCatalog()
        let floating = FloatingWindowController()
        self.settings = settings
        self.catalog = catalog
        self.floating = floating
        translator = LiveTranslator(floating: floating, catalog: catalog)
        translator.settings = settings
    }

    var targetLanguage: Locale.Language? { catalog.option(id: settings.targetLanguageID)?.language }
    var sourceLanguage: Locale.Language? { catalog.option(id: settings.sourceLanguageID)?.language }

    // MARK: - Startup

    func start() async {
        guard !didStart else { return }
        didStart = true
        settings.save()

        floating.setUp(autoStart: settings.autoStartFloatingWindow)
        floating.onPauseChanged = { [weak self] paused in self?.translator.setPaused(paused) }
        translator.refreshOverlay()

        SignalCenter.shared.observe(.frameReady) { [weak self] in
            Task { @MainActor in self?.translator.frameDidArrive() }
        }
        SignalCenter.shared.observe(.broadcastStarted) { [weak self] in
            Task { @MainActor in self?.refreshBroadcastState(force: true) }
        }
        SignalCenter.shared.observe(.broadcastStopped) { [weak self] in
            Task { @MainActor in self?.refreshBroadcastState(force: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        await catalog.load()
        if catalog.option(id: settings.targetLanguageID) == nil {
            settings.targetLanguageID = catalog.defaultTargetID() ?? ""
        }
        if let source = settings.sourceLanguageID, catalog.option(id: source) == nil {
            settings.sourceLanguageID = nil
        }
        refreshBroadcastState(force: true)
        await refreshPairStatus()
        translator.reprocess()
    }

    func appBecameActive() {
        refreshBroadcastState(force: false)
        Task { await refreshPairStatus() }
    }

    private func tick() {
        tickCount += 1
        refreshBroadcastState(force: false)
        // Re-send the current frame now and then so the floating window never looks stale.
        if tickCount % 3 == 0 { translator.refreshOverlay() }
    }

    private func refreshBroadcastState(force: Bool) {
        let alive = SharedDefaults.isBroadcastAlive
        guard force || alive != isBroadcasting else { return }
        let wasBroadcasting = isBroadcasting
        isBroadcasting = alive
        translator.isBroadcasting = alive
        if alive && !wasBroadcasting { translator.reprocess() } else { translator.refreshOverlay() }
    }

    // MARK: - Settings

    private func settingsDidChange(from old: AppSettings) {
        guard settings != old else { return }
        settings.save()
        translator.settings = settings
        floating.setAutoStart(settings.autoStartFloatingWindow)

        let languagesChanged = old.sourceLanguageID != settings.sourceLanguageID || old.targetLanguageID != settings.targetLanguageID
        let recognitionChanged = languagesChanged
            || old.regionRect != settings.regionRect
            || old.rotation != settings.rotation
            || old.languageCorrection != settings.languageCorrection
            || old.smallText != settings.smallText
            || old.onlyLongestText != settings.onlyLongestText
            || old.preferHighFidelity != settings.preferHighFidelity

        if languagesChanged {
            translator.clear()
            Task { await refreshPairStatus() }
        }
        if recognitionChanged {
            translator.reprocess()
        } else {
            translator.refreshOverlay()
        }
    }

    func swapLanguages() {
        guard let source = settings.sourceLanguageID else { return }
        let target = settings.targetLanguageID
        settings.sourceLanguageID = target
        settings.targetLanguageID = source
    }

    // MARK: - Language downloads

    func refreshPairStatus() async {
        guard let target = targetLanguage else {
            pairStatus = .unknown
            return
        }
        var states: [String: TranslationEngine.PairState] = [:]
        for option in catalog.options where !option.language.isSameLanguage(as: target) {
            states[option.id] = await translator.engine.state(from: option.language, to: target)
        }
        sourceStates = states

        if let source = sourceLanguage {
            if source.isSameLanguage(as: target) {
                pairStatus = .sameLanguage
            } else {
                var state = states[source.maximalIdentifier]
                if state == nil { state = await translator.engine.state(from: source, to: target) }
                switch state ?? .unsupported {
                case .ready: pairStatus = .ready
                case .needsDownload: pairStatus = .needsDownload
                case .unsupported: pairStatus = .unsupported
                }
            }
        } else {
            pairStatus = .autoDetect(installed: states.values.filter { $0 == .ready }.count, total: states.count)
        }
    }

    /// Shows the system download sheet for `source` → current target.
    func requestDownload(from source: Locale.Language) {
        guard let target = targetLanguage else { return }
        downloadError = nil
        if downloadConfiguration?.source == source && downloadConfiguration?.target == target {
            downloadConfiguration?.invalidate()
        } else {
            downloadConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    func performDownload(using session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
        } catch {
            downloadError = error.localizedDescription
        }
        translator.engine.refreshAvailability()
        await refreshPairStatus()
        translator.reprocess()
    }
}

/// Opens the system "Screen Broadcast" sheet with FloatLingo's extension preselected.
@MainActor
final class BroadcastLauncher {
    let picker: RPSystemBroadcastPickerView

    init() {
        picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.showsMicrophoneButton = false
        picker.preferredExtension = Self.extensionBundleIdentifier
    }

    func open() {
        if let button = Self.firstButton(in: picker) {
            button.sendActions(for: .touchUpInside)
        }
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let nested = firstButton(in: subview) { return nested }
        }
        return nil
    }

    /// Looked up at runtime because sideloading tools may change bundle identifiers.
    static let extensionBundleIdentifier: String? = {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        else { return nil }
        for item in items where item.pathExtension == "appex" {
            guard let bundle = Bundle(url: item),
                  let info = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  info["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload"
            else { continue }
            return bundle.bundleIdentifier
        }
        return nil
    }()
}
