import Foundation

/// Settings and status values exchanged between the app and the broadcast extension
/// through the App Group's `UserDefaults`.
enum SharedKeys {
    /// Frames per second the extension forwards to the app (Double).
    static let captureFPS = "fl.captureFPS"
    /// Longest side, in pixels, of forwarded frames. 0 = native resolution (Int).
    static let captureLongSide = "fl.captureLongSide"
    /// `Date().timeIntervalSince1970` of the extension's last sign of life (Double).
    static let heartbeat = "fl.broadcastHeartbeat"
    /// Whether a broadcast is currently running (Bool).
    static let broadcastActive = "fl.broadcastActive"
}

enum SharedDefaults {
    static let defaultFPS: Double = 2
    static let defaultLongSide: Int = 1920

    static var captureFPS: Double {
        get {
            let value = AppGroup.defaults.double(forKey: SharedKeys.captureFPS)
            return value > 0 ? min(max(value, 0.25), 10) : defaultFPS
        }
        set { AppGroup.defaults.set(newValue, forKey: SharedKeys.captureFPS) }
    }

    static var captureLongSide: Int {
        get {
            guard AppGroup.defaults.object(forKey: SharedKeys.captureLongSide) != nil else { return defaultLongSide }
            return max(0, AppGroup.defaults.integer(forKey: SharedKeys.captureLongSide))
        }
        set { AppGroup.defaults.set(newValue, forKey: SharedKeys.captureLongSide) }
    }

    /// True when the extension reported in during the last few seconds.
    static var isBroadcastAlive: Bool {
        guard AppGroup.defaults.bool(forKey: SharedKeys.broadcastActive) else { return false }
        let last = AppGroup.defaults.double(forKey: SharedKeys.heartbeat)
        return Date().timeIntervalSince1970 - last < 5
    }
}
