import ActivityKit
import Foundation

/// Live Activity showing the newest translation in the Dynamic Island and on the Lock Screen.
/// Shared by the app (which starts and updates it) and the widget extension (which draws it).
struct TranslationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Newest translated line.
        var translation: String
        /// The text it was translated from.
        var original: String
        /// e.g. "中文 → English".
        var pair: String
        /// Short status such as "Live" or "Paused".
        var status: String
    }

    /// Kept for future use; Live Activities need at least one static attribute type.
    var name: String = "FloatLingo"
}
