import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import ReplayKit

/// Broadcast Upload Extension.
///
/// Runs in its own process with a ~50 MB memory limit, so it does as little as possible:
/// it throttles the incoming screen frames, skips frames that did not change, downsamples
/// the luma (brightness) plane and drops it into the App Group for the app to OCR + translate.
final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private var forceNextFrame = true

    private var lastFrameTime: TimeInterval = 0
    private var lastWriteTime: TimeInterval = 0
    private var lastSettingsRead: TimeInterval = 0
    private var sequence: UInt64 = 0

    private var fps = SharedDefaults.defaultFPS
    private var longSide = SharedDefaults.defaultLongSide

    private var scaled = PlanarBuffer()
    private var converted = PlanarBuffer()
    private var thumbnail = PlanarBuffer()
    private var previousThumbnail: [UInt8] = []

    private static let thumbnailSize = 96

    // MARK: Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard AppGroup.isAvailable else {
            let error = NSError(domain: "FloatLingo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "FloatLingo can't reach its App Group (\(AppGroup.identifier)). Re-install the app with the App Groups capability enabled for both the app and the broadcast extension.",
            ])
            finishBroadcastWithError(error)
            return
        }
        readSettings()
        AppGroup.defaults.set(true, forKey: SharedKeys.broadcastActive)
        writeHeartbeat()
        SignalCenter.shared.observe(.requestFreshFrame) { [weak self] in
            self?.setForceNextFrame()
        }
        SignalCenter.shared.post(.broadcastStarted)
    }

    override func broadcastResumed() {
        setForceNextFrame()
    }

    override func broadcastFinished() {
        AppGroup.defaults.set(false, forKey: SharedKeys.broadcastActive)
        SignalCenter.shared.post(.broadcastStopped)
        scaled.free(); converted.free(); thumbnail.free()
    }

    // MARK: Frames

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSettingsRead > 1 {
            lastSettingsRead = now
            readSettings()
            writeHeartbeat()
        }

        let force = consumeForceNextFrame()
        guard force || now - lastFrameTime >= 1.0 / fps else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = Self.orientation(of: sampleBuffer)

        autoreleasepool {
            handle(pixelBuffer, orientation: orientation, force: force, now: now)
        }
    }

    private func handle(_ pixelBuffer: CVPixelBuffer, orientation: UInt32, force: Bool, now: TimeInterval) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard var luma = lumaBuffer(of: pixelBuffer) else { return }

        // Downsample so OCR in the app stays fast and the file stays small.
        let srcWidth = Int(luma.width), srcHeight = Int(luma.height)
        let longest = max(srcWidth, srcHeight)
        if longSide > 0, longest > longSide {
            let scale = Double(longSide) / Double(longest)
            let width = max(1, Int((Double(srcWidth) * scale).rounded()))
            let height = max(1, Int((Double(srcHeight) * scale).rounded()))
            guard var destination = scaled.buffer(width: width, height: height) else { return }
            guard vImageScale_Planar8(&luma, &destination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return }
            luma = destination
        }

        // Skip frames that look the same as the previous one (static menus, paused dialogue…).
        let changed = hasChanged(luma)
        guard force || changed || now - lastWriteTime > 15 else { return }

        sequence &+= 1
        let byteCount = Int(luma.height) * luma.rowBytes
        do {
            try FrameFile.write(
                width: Int(luma.width),
                height: Int(luma.height),
                bytesPerRow: luma.rowBytes,
                orientation: orientation,
                timestamp: Date().timeIntervalSince1970,
                sequence: sequence,
                pixels: UnsafeRawBufferPointer(start: luma.data, count: byteCount)
            )
            lastWriteTime = now
            SignalCenter.shared.post(.frameReady)
        } catch {
            // Disk full or container missing: try again on the next frame.
        }
    }

    /// Returns a vImage view of the brightness channel of a ReplayKit frame.
    private func lumaBuffer(of pixelBuffer: CVPixelBuffer) -> vImage_Buffer? {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            return vImage_Buffer(
                data: base,
                height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
                width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            )

        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard let out = converted.buffer(width: width, height: height), let outData = out.data else { return nil }
            let src = base.assumingMemoryBound(to: UInt8.self)
            let dst = outData.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let srcRow = src + y * srcRowBytes
                let dstRow = dst + y * out.rowBytes
                for x in 0..<width {
                    let p = srcRow + x * 4 // B G R A
                    let value = (29 * Int(p[0]) + 150 * Int(p[1]) + 77 * Int(p[2])) >> 8
                    dstRow[x] = UInt8(truncatingIfNeeded: value)
                }
            }
            return out

        default:
            return nil
        }
    }

    private func hasChanged(_ luma: vImage_Buffer) -> Bool {
        var source = luma
        let side = Self.thumbnailSize
        guard var small = thumbnail.buffer(width: side, height: side), let smallData = small.data else { return true }
        guard vImageScale_Planar8(&source, &small, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return true }

        let pointer = smallData.assumingMemoryBound(to: UInt8.self)
        var current = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                current[y * side + x] = pointer[y * small.rowBytes + x]
            }
        }
        defer { previousThumbnail = current }
        guard previousThumbnail.count == current.count else { return true }

        var total = 0
        var maximum = 0
        for i in 0..<current.count {
            let diff = abs(Int(current[i]) - Int(previousThumbnail[i]))
            total += diff
            if diff > maximum { maximum = diff }
        }
        let mean = Double(total) / Double(current.count)
        // A local change (new dialogue line) moves a few cells a lot; a global change moves the mean.
        return mean > 0.6 || maximum > 18
    }

    // MARK: Helpers

    private static func orientation(of sampleBuffer: CMSampleBuffer) -> UInt32 {
        if let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            return value.uint32Value
        }
        return 1 // .up
    }

    private func readSettings() {
        fps = SharedDefaults.captureFPS
        longSide = SharedDefaults.captureLongSide
    }

    private func writeHeartbeat() {
        AppGroup.defaults.set(Date().timeIntervalSince1970, forKey: SharedKeys.heartbeat)
    }

    private func setForceNextFrame() {
        lock.lock(); forceNextFrame = true; lock.unlock()
    }

    private func consumeForceNextFrame() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = forceNextFrame
        forceNextFrame = false
        return value
    }
}

/// A reusable 8-bit single channel buffer, grown on demand.
private struct PlanarBuffer {
    private var storage: UnsafeMutableRawPointer?
    private var capacity = 0

    mutating func buffer(width: Int, height: Int) -> vImage_Buffer? {
        let rowBytes = (width + 15) & ~15
        let needed = rowBytes * height
        if needed > capacity {
            free()
            storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
            capacity = needed
        }
        guard let storage else { return nil }
        return vImage_Buffer(data: storage, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
    }

    mutating func free() {
        storage?.deallocate()
        storage = nil
        capacity = 0
    }
}
