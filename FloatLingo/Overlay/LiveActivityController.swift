import ActivityKit
import Foundation

/// Shows the newest translation in the Dynamic Island and on the Lock Screen.
///
/// This is the closest iOS gets to text floating over a full-screen game without a window:
/// the Dynamic Island shows the start of the line, a long-press shows the whole line, and
/// (optionally) each new line pops the island open for a moment — or shows a banner on
/// iPhones without a Dynamic Island.
@MainActor
final class LiveActivityController {
    var popUpNewLines = false

    private var activity: Activity<TranslationActivityAttributes>?
    private var state = TranslationActivityAttributes.ContentState(translation: "", original: "", pair: "", status: "Live")
    private var pendingFlush = false
    private var lastSent = Date.distantPast
    private var lastAlert = Date.distantPast
    private var alertPending = false

    var isRunning: Bool { activity != nil }

    /// Must be called while the app is in the foreground.
    func start(pair: String) {
        state.pair = pair
        if activity == nil {
            activity = Activity<TranslationActivityAttributes>.activities.first
        }
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else {
            flush()
            return
        }
        activity = try? Activity.request(
            attributes: TranslationActivityAttributes(),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }

    func stop() {
        let current = activity ?? Activity<TranslationActivityAttributes>.activities.first
        activity = nil
        guard let current else { return }
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    func show(translation: String, original: String) {
        state.translation = String(translation.prefix(280))
        state.original = String(original.prefix(120))
        alertPending = true
        scheduleFlush()
    }

    func setStatus(_ status: String, pair: String) {
        guard status != state.status || pair != state.pair else { return }
        state.status = status
        state.pair = pair
        scheduleFlush()
    }

    /// Coalesces bursts of updates (at most ~3 per second).
    private func scheduleFlush() {
        guard activity != nil, !pendingFlush else { return }
        let wait = max(0, 0.35 - Date().timeIntervalSince(lastSent))
        pendingFlush = true
        Task {
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            pendingFlush = false
            flush()
        }
    }

    private func flush() {
        guard let activity else { return }
        lastSent = Date()
        var alert: AlertConfiguration?
        if popUpNewLines, alertPending, !state.translation.isEmpty, Date().timeIntervalSince(lastAlert) > 2.5 {
            alert = AlertConfiguration(
                title: LocalizedStringResource(stringLiteral: state.pair),
                body: LocalizedStringResource(stringLiteral: state.translation),
                sound: .named("silence.wav")
            )
            lastAlert = Date()
        }
        alertPending = false
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            if let alert {
                await activity.update(content, alertConfiguration: alert)
            } else {
                await activity.update(content)
            }
        }
    }
}
