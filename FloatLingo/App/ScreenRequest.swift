import AppIntents
import Foundation

/// A request to show the translated screen, made from outside the app's UI (Shortcuts,
/// Back Tap, the Action Button). Survives a cold launch: the app checks it when it becomes active.
enum ScreenRequest {
    static let notification = Notification.Name("FloatLingo.showTranslatedScreen")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending = false

    static func request() {
        lock.lock(); pending = true; lock.unlock()
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = pending
        pending = false
        return value
    }
}

/// "Show Translated Screen": opens FloatLingo on the game screen with every word translated in
/// place. Add it to Back Tap (Settings › Accessibility › Touch › Back Tap) or the Action Button.
struct ShowTranslatedScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Translated Screen"
    static let description = IntentDescription("Shows the screen you were just looking at with every word translated in place.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ScreenRequest.request()
        return .result()
    }
}

struct FloatLingoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowTranslatedScreenIntent(),
            phrases: [
                "Translate my screen with \(.applicationName)",
                "Show \(.applicationName) translation",
            ],
            shortTitle: "Translated Screen",
            systemImageName: "character.bubble"
        )
    }
}
