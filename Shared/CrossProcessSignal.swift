import Foundation

/// Payload-free notifications between the app and the broadcast extension,
/// delivered through the Darwin notify center.
enum CrossProcessSignal: String, CaseIterable {
    case frameReady = "com.floatlingo.signal.frameReady"
    case broadcastStarted = "com.floatlingo.signal.broadcastStarted"
    case broadcastStopped = "com.floatlingo.signal.broadcastStopped"
    /// Sent by the app: "send me a frame now even if the screen did not change".
    case requestFreshFrame = "com.floatlingo.signal.requestFreshFrame"
}

final class SignalCenter: @unchecked Sendable {
    static let shared = SignalCenter()

    private var handlers: [String: [() -> Void]] = [:]
    private let lock = NSLock()

    private init() {}

    func post(_ signal: CrossProcessSignal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(signal.rawValue as CFString),
            nil, nil, true
        )
    }

    /// Handlers are called on the thread that delivers Darwin notifications (normally the main thread).
    func observe(_ signal: CrossProcessSignal, handler: @escaping () -> Void) {
        lock.lock()
        let isFirst = handlers[signal.rawValue] == nil
        handlers[signal.rawValue, default: []].append(handler)
        lock.unlock()
        guard isFirst else { return }

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let center = Unmanaged<SignalCenter>.fromOpaque(observer).takeUnretainedValue()
                center.dispatch(name.rawValue as String)
            },
            signal.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func dispatch(_ name: String) {
        lock.lock()
        let current = handlers[name] ?? []
        lock.unlock()
        current.forEach { $0() }
    }
}
