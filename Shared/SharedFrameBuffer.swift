import Foundation
import Synchronization

/// A grayscale (8-bit luma) screen frame handed from the broadcast extension to the app.
struct CapturedFrame {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    /// `CGImagePropertyOrientation` raw value describing how to rotate the pixels to be upright.
    var orientation: UInt32
    /// `Date().timeIntervalSince1970` when the extension received the frame.
    var timestamp: Double
    /// Increases by one for every published frame.
    var sequence: UInt64
    var pixels: Data
}

/// Shared-memory double buffer between the broadcast extension (writer) and the app (reader).
///
/// Both processes `mmap` the same file in the App Group container, so a frame is handed over
/// with a single `memcpy` — no file is created, renamed or re-read for every frame, which keeps
/// latency low and avoids wearing out flash storage. Each of the two slots is protected by a
/// sequence counter (a "seqlock"): odd while being written, even when complete; a reader that
/// sees the counter change during its copy simply retries.
final class SharedFrameBuffer: @unchecked Sendable {
    static let slotCapacity = 6 * 1024 * 1024
    private static let magic: UInt32 = 0x464C_5348 // "FLSH"
    private static let version: UInt32 = 1
    private static let headerSize = 64
    private static let slotHeaderSize = 64
    private static var fileSize: Int { headerSize + 2 * (slotHeaderSize + slotCapacity) }

    // Global header offsets.
    private static let magicOffset = 0
    private static let versionOffset = 4
    private static let latestSlotOffset = 8
    private static let publishCountOffset = 16
    // Slot header offsets.
    private static let seqOffset = 0
    private static let widthOffset = 8
    private static let heightOffset = 12
    private static let bytesPerRowOffset = 16
    private static let orientationOffset = 20
    private static let timestampOffset = 24

    /// The app's reader, attached on first use.
    static let shared: SharedFrameBuffer? = SharedFrameBuffer()

    private let base: UnsafeMutableRawPointer
    private let length: Int
    private let descriptor: Int32

    init?() {
        guard let url = AppGroup.containerURL?.appendingPathComponent("frames.shm", isDirectory: false) else { return nil }
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        let length = Self.fileSize
        var info = stat()
        if fstat(fd, &info) != 0 || Int(info.st_size) < length {
            guard ftruncate(fd, off_t(length)) == 0 else {
                close(fd)
                return nil
            }
        }
        guard let pointer = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              pointer != UnsafeMutableRawPointer(bitPattern: -1)
        else {
            close(fd)
            return nil
        }
        base = pointer
        self.length = length
        descriptor = fd

        if base.load(fromByteOffset: Self.magicOffset, as: UInt32.self) != Self.magic
            || base.load(fromByteOffset: Self.versionOffset, as: UInt32.self) != Self.version {
            memset(base, 0, Self.headerSize + 2 * Self.slotHeaderSize)
            base.storeBytes(of: Self.version, toByteOffset: Self.versionOffset, as: UInt32.self)
            fence()
            base.storeBytes(of: Self.magic, toByteOffset: Self.magicOffset, as: UInt32.self)
        }
    }

    deinit {
        munmap(base, length)
        close(descriptor)
    }

    private func fence() {
        atomicMemoryFence(ordering: .sequentiallyConsistent)
    }

    private func slotHeader(_ slot: Int) -> UnsafeMutableRawPointer {
        base + Self.headerSize + slot * (Self.slotHeaderSize + Self.slotCapacity)
    }

    private func slotData(_ slot: Int) -> UnsafeMutableRawPointer {
        slotHeader(slot) + Self.slotHeaderSize
    }

    var publishCount: UInt64 {
        fence()
        return base.load(fromByteOffset: Self.publishCountOffset, as: UInt64.self)
    }

    // MARK: Writer (broadcast extension)

    /// Copies a frame into the slot that isn't the most recent one, then publishes it.
    @discardableResult
    func publish(width: Int, height: Int, bytesPerRow: Int, orientation: UInt32, timestamp: Double,
                 pixels: UnsafeRawPointer) -> Bool {
        let byteCount = height * bytesPerRow
        guard width > 0, height > 0, bytesPerRow >= width, byteCount <= Self.slotCapacity else { return false }

        let latest = Int(base.load(fromByteOffset: Self.latestSlotOffset, as: UInt32.self))
        let slot = latest == 0 ? 1 : 0
        let header = slotHeader(slot)

        let current = header.load(fromByteOffset: Self.seqOffset, as: UInt64.self)
        let writing = current % 2 == 0 ? current &+ 1 : current &+ 2 // odd = being written
        header.storeBytes(of: writing, toByteOffset: Self.seqOffset, as: UInt64.self)
        fence()

        memcpy(slotData(slot), pixels, byteCount)
        header.storeBytes(of: UInt32(width), toByteOffset: Self.widthOffset, as: UInt32.self)
        header.storeBytes(of: UInt32(height), toByteOffset: Self.heightOffset, as: UInt32.self)
        header.storeBytes(of: UInt32(bytesPerRow), toByteOffset: Self.bytesPerRowOffset, as: UInt32.self)
        header.storeBytes(of: orientation, toByteOffset: Self.orientationOffset, as: UInt32.self)
        header.storeBytes(of: timestamp, toByteOffset: Self.timestampOffset, as: Double.self)
        fence()

        header.storeBytes(of: writing &+ 1, toByteOffset: Self.seqOffset, as: UInt64.self) // even = complete
        fence()
        base.storeBytes(of: UInt32(slot), toByteOffset: Self.latestSlotOffset, as: UInt32.self)
        let count = base.load(fromByteOffset: Self.publishCountOffset, as: UInt64.self)
        base.storeBytes(of: count &+ 1, toByteOffset: Self.publishCountOffset, as: UInt64.self)
        fence()
        return true
    }

    // MARK: Reader (app)

    /// Returns a copy of the newest complete frame, or `nil` when there is none (or it is torn).
    func readLatest() -> CapturedFrame? {
        for _ in 0..<4 {
            fence()
            let count = base.load(fromByteOffset: Self.publishCountOffset, as: UInt64.self)
            guard count > 0 else { return nil }
            let slot = Int(base.load(fromByteOffset: Self.latestSlotOffset, as: UInt32.self)) == 1 ? 1 : 0
            let header = slotHeader(slot)

            let before = header.load(fromByteOffset: Self.seqOffset, as: UInt64.self)
            guard before % 2 == 0 else { continue }
            fence()
            let width = Int(header.load(fromByteOffset: Self.widthOffset, as: UInt32.self))
            let height = Int(header.load(fromByteOffset: Self.heightOffset, as: UInt32.self))
            let bytesPerRow = Int(header.load(fromByteOffset: Self.bytesPerRowOffset, as: UInt32.self))
            let orientation = header.load(fromByteOffset: Self.orientationOffset, as: UInt32.self)
            let timestamp = header.load(fromByteOffset: Self.timestampOffset, as: Double.self)
            let byteCount = height * bytesPerRow
            guard width > 0, height > 0, bytesPerRow >= width, byteCount <= Self.slotCapacity else { return nil }
            let pixels = Data(bytes: slotData(slot), count: byteCount)
            fence()
            let after = header.load(fromByteOffset: Self.seqOffset, as: UInt64.self)
            guard before == after else { continue }

            return CapturedFrame(width: width, height: height, bytesPerRow: bytesPerRow, orientation: orientation,
                                 timestamp: timestamp, sequence: count, pixels: pixels)
        }
        return nil
    }
}
