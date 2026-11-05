import CoreGraphics
import Foundation

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    /// A dimmed copy of the screen with each translation placed on top of its original text.
    case overlay
    /// Translated lines stacked like subtitles in a slim bar.
    case subtitles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overlay: "Lens (translations on the screen)"
        case .subtitles: "Subtitles bar"
        }
    }
}

enum OverlayTheme: String, Codable, CaseIterable, Identifiable {
    case dark, black, light, yellow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: "Dark glass"
        case .black: "Black"
        case .light: "Light"
        case .yellow: "Yellow subtitles"
        }
    }
}

enum WindowShape: String, Codable, CaseIterable, Identifiable {
    case slim, banner, wide, standard, square, tall, matchScreen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .slim: "Slim bar 3:1"
        case .wide: "Wide 16:9"
        case .banner: "Banner 2:1"
        case .standard: "4:3"
        case .square: "Square"
        case .tall: "Tall 9:16"
        case .matchScreen: "Match captured area"
        }
    }

    /// Canvas size of the floating window, in pixels.
    func canvasSize(regionAspect: CGFloat) -> CGSize {
        let longSide: CGFloat = 1280
        let aspect: CGFloat
        switch self {
        case .slim: aspect = 3
        case .wide: aspect = 16.0 / 9.0
        case .banner: aspect = 2.0
        case .standard: aspect = 4.0 / 3.0
        case .square: aspect = 1
        case .tall: aspect = 9.0 / 16.0
        case .matchScreen: aspect = min(max(regionAspect, 0.45), 2.4)
        }
        let size = aspect >= 1
            ? CGSize(width: longSide, height: longSide / aspect)
            : CGSize(width: longSide * aspect, height: longSide)
        // Even dimensions keep video pipelines happy.
        return CGSize(width: (size.width / 2).rounded() * 2, height: (size.height / 2).rounded() * 2)
    }
}

enum CaptureQuality: Int, Codable, CaseIterable, Identifiable {
    case batterySaver = 1280
    case balanced = 1920
    case maximum = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .batterySaver: "Battery saver"
        case .balanced: "Balanced"
        case .maximum: "Maximum (small text)"
        }
    }
}

enum CaptureRegion: String, Codable, CaseIterable, Identifiable {
    case fullScreen, topHalf, bottomHalf, middle, bottomThird, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullScreen: "Full screen"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .middle: "Middle"
        case .bottomThird: "Bottom third (dialogue)"
        case .custom: "Custom"
        }
    }
}

enum RotationOverride: Int, Codable, CaseIterable, Identifiable {
    case automatic = -1, none = 0, clockwise90 = 90, upsideDown = 180, counterClockwise90 = 270
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .none: "None"
        case .clockwise90: "90° clockwise"
        case .upsideDown: "180°"
        case .counterClockwise90: "90° counter-clockwise"
        }
    }
}

/// All user preferences. Stored as JSON in the app's standard defaults; the few values the
/// broadcast extension needs are mirrored into the App Group (see `SharedDefaults`).
struct AppSettings: Codable, Equatable {
    /// `nil` = auto-detect. Otherwise a `Locale.Language.maximalIdentifier`.
    var sourceLanguageID: String? = nil
    var targetLanguageID: String = ""

    var displayMode: DisplayMode = .overlay
    var theme: OverlayTheme = .dark
    /// Shape of the subtitles bar. Lens mode always matches the captured area.
    var windowShape: WindowShape = .slim
    var fontScale: Double = 1.0
    var showOriginal: Bool = false
    var onlyLongestText: Bool = false
    var autoStartFloatingWindow: Bool = true

    var captureFPS: Double = SharedDefaults.defaultFPS
    var captureQuality: CaptureQuality = .balanced
    var region: CaptureRegion = .fullScreen
    var customTop: Double = 0
    var customBottom: Double = 1
    var customLeft: Double = 0
    var customRight: Double = 1
    var rotation: RotationOverride = .automatic
    var languageCorrection: Bool = true
    var smallText: Bool = true
    var preferHighFidelity: Bool = false
    var dynamicIsland: Bool = true
    var popUpNewLines: Bool = false

    /// Area of the (upright) screen to read, normalized, origin top-left.
    var regionRect: CGRect {
        switch region {
        case .fullScreen: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .middle: return CGRect(x: 0, y: 0.25, width: 1, height: 0.5)
        case .bottomThird: return CGRect(x: 0, y: 2.0 / 3.0, width: 1, height: 1.0 / 3.0)
        case .custom:
            let top = min(max(customTop, 0), 0.95), bottom = min(max(customBottom, top + 0.05), 1)
            let left = min(max(customLeft, 0), 0.95), right = min(max(customRight, left + 0.05), 1)
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    enum CodingKeys: String, CodingKey {
        case sourceLanguageID, targetLanguageID, displayMode, theme, windowShape, fontScale, showOriginal
        case onlyLongestText, autoStartFloatingWindow, captureFPS, captureQuality, region
        case customTop, customBottom, customLeft, customRight, rotation, languageCorrection, smallText
        case preferHighFidelity, dynamicIsland, popUpNewLines
    }

    static let storageKey = "fl.appSettings.v2"

    /// The floating window's shape for the current display mode.
    var effectiveShape: WindowShape {
        displayMode == .overlay ? .matchScreen : windowShape
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        SharedDefaults.captureFPS = captureFPS
        SharedDefaults.captureLongSide = captureQuality.rawValue
    }
}

// MARK: - Tolerant decoding

extension AppSettings {
    /// Missing or unknown values fall back to their defaults, so settings survive app updates.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) {
            if let decoded = try? container.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        read(.sourceLanguageID, into: &sourceLanguageID)
        read(.targetLanguageID, into: &targetLanguageID)
        read(.displayMode, into: &displayMode)
        read(.theme, into: &theme)
        read(.windowShape, into: &windowShape)
        read(.fontScale, into: &fontScale)
        read(.showOriginal, into: &showOriginal)
        read(.onlyLongestText, into: &onlyLongestText)
        read(.autoStartFloatingWindow, into: &autoStartFloatingWindow)
        read(.captureFPS, into: &captureFPS)
        read(.captureQuality, into: &captureQuality)
        read(.region, into: &region)
        read(.customTop, into: &customTop)
        read(.customBottom, into: &customBottom)
        read(.customLeft, into: &customLeft)
        read(.customRight, into: &customRight)
        read(.rotation, into: &rotation)
        read(.languageCorrection, into: &languageCorrection)
        read(.smallText, into: &smallText)
        read(.preferHighFidelity, into: &preferHighFidelity)
        read(.dynamicIsland, into: &dynamicIsland)
        read(.popUpNewLines, into: &popUpNewLines)
    }
}

// MARK: - One-tap setups

enum QuickSetup: String, CaseIterable, Identifiable {
    case chineseGame, dialogue, anyApp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chineseGame: "Chinese game"
        case .dialogue: "Dialogue bar"
        case .anyApp: "Any app"
        }
    }

    var systemImage: String {
        switch self {
        case .chineseGame: "gamecontroller"
        case .dialogue: "text.bubble"
        case .anyApp: "rectangle.dashed"
        }
    }

    /// - Parameter chineseID: the catalog id of Simplified Chinese, used by `.chineseGame`.
    func apply(to settings: inout AppSettings, chineseID: String?) {
        switch self {
        case .chineseGame:
            if let chineseID { settings.sourceLanguageID = chineseID }
            settings.region = .fullScreen
            settings.displayMode = .overlay
            settings.onlyLongestText = false
            settings.languageCorrection = false
            settings.smallText = true
        case .dialogue:
            settings.region = .bottomThird
            settings.displayMode = .subtitles
            settings.windowShape = .slim
            settings.onlyLongestText = true
            settings.languageCorrection = false
            settings.smallText = true
        case .anyApp:
            settings.region = .fullScreen
            settings.displayMode = .overlay
            settings.onlyLongestText = false
            settings.languageCorrection = true
            settings.smallText = true
        }
    }

    func isApplied(in settings: AppSettings, chineseID: String?) -> Bool {
        var copy = settings
        apply(to: &copy, chineseID: chineseID)
        return copy == settings
    }
}
