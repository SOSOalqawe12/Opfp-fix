import AVFoundation
import AVKit
import UIKit

/// A view backed by an `AVSampleBufferDisplayLayer`; the layer is what iOS lifts into the
/// Picture-in-Picture window that floats above every other app.
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Thread-safe Bool, readable from AVKit's synchronous callbacks.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Owns the Picture-in-Picture controller that shows translations on top of other apps.
///
/// iOS does not allow apps to draw directly over other apps. Picture in Picture is the only
/// public, App Store-safe surface that floats over everything, so translations are rendered
/// into video frames and played in a PiP window. The PiP play/pause button pauses translation.
@MainActor
final class FloatingWindowController: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var isPaused = false
    @Published private(set) var lastError: String?

    let view = SampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    var onPauseChanged: ((Bool) -> Void)?
    /// Called when the user taps the floating window's "back to app" button.
    var onRestore: (() -> Void)?

    nonisolated private let pausedFlag = AtomicFlag(false)
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func setUp(autoStart: Bool) {
        guard controller == nil else {
            controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart
            return
        }
        activateAudioSession()
        guard isSupported else {
            lastError = "Picture in Picture isn't supported on this device."
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = autoStart
        controller.requiresLinearPlayback = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        self.controller = controller
    }

    func setAutoStart(_ enabled: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    func start() {
        activateAudioSession()
        guard let controller else { return }
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            lastError = "The floating window isn't ready yet. Keep FloatLingo open for a second and try again."
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        pausedFlag.value = paused
        isPaused = paused
        controller?.invalidatePlaybackState()
        onPauseChanged?(paused)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let renderer = view.displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    private func activateAudioSession() {
        // PiP needs a playback audio session. `mixWithOthers` keeps the game's sound playing.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            lastError = "Audio session error: \(error.localizedDescription)"
        }
    }
}

extension FloatingWindowController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            self.lastError = nil
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.isActive = false
            self.lastError = "Couldn't open the floating window: \(message)"
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in self.onRestore?() }
        completionHandler(true)
    }
}

extension FloatingWindowController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.setPaused(!playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // An infinite range makes PiP present this as live content (no scrubber).
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        pausedFlag.value
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
