import Foundation
import Synchronization

/// A screen frame handed from the broadcast extension to the app: an 8-bit luma (brightness)
/// plane used for OCR, plus — when available — the interleaved CbCr color plane (4:2:0), used
/// to show the translated screen in color.
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
    /// `FrameColorFormat` raw value.
    var colorFormat: UInt32 = 0
    var chromaWidth = 0
    var chromaHeight = 0
    var chromaBytesPerRow = 0
    var chroma: Data?
}

enum FrameColorFormat: UInt32 {
    case grayOnly = 0
    case fullRange420 = 1
    case videoRange420 = 2
}

/// Optional color plane passed to `SharedFrameBuffer.publish`.
struct ChromaPlane {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var format: FrameColorFormat
    var pixels: UnsafeRawPointer
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
    private static let version: UInt32 = 2
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
    private static let chromaWidthOffset = 32
    private static let chromaHeightOffset = 36
    private static let chromaBytesPerRowOffset = 40
    private static let colorFormatOffset = 44

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
                 pixels: UnsafeRawPointer, chroma: ChromaPlane? = nil) -> Bool {
        let byteCount = height * bytesPerRow
        guard width > 0, height > 0, bytesPerRow >= width, byteCount <= Self.slotCapacity else { return false }
        var color = chroma
        if let plane = color, byteCount + plane.height * plane.bytesPerRow > Self.slotCapacity {
            color = nil // keep OCR going in gray if color doesn't fit
        }

        let latest = Int(base.load(fromByteOffset: Self.latestSlotOffset, as: UInt32.self))
        let slot = latest == 0 ? 1 : 0
        let header = slotHeader(slot)

        let current = header.load(fromByteOffset: Self.seqOffset, as: UInt64.self)
        let writing = current % 2 == 0 ? current &+ 1 : current &+ 2 // odd = being written
        header.storeBytes(of: writing, toByteOffset: Self.seqOffset, as: UInt64.self)
        fence()

        memcpy(slotData(slot), pixels, byteCount)
        if let plane = color {
            memcpy(slotData(slot) + byteCount, plane.pixels, plane.height * plane.bytesPerRow)
        }
        header.storeBytes(of: UInt32(color?.width ?? 0), toByteOffset: Self.chromaWidthOffset, as: UInt32.self)
        header.storeBytes(of: UInt32(color?.height ?? 0), toByteOffset: Self.chromaHeightOffset, as: UInt32.self)
        header.storeBytes(of: UInt32(color?.bytesPerRow ?? 0), toByteOffset: Self.chromaBytesPerRowOffset, as: UInt32.self)
        header.storeBytes(of: color?.format.rawValue ?? 0, toByteOffset: Self.colorFormatOffset, as: UInt32.self)
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

            let chromaWidth = Int(header.load(fromByteOffset: Self.chromaWidthOffset, as: UInt32.self))
            let chromaHeight = Int(header.load(fromByteOffset: Self.chromaHeightOffset, as: UInt32.self))
            let chromaBytesPerRow = Int(header.load(fromByteOffset: Self.chromaBytesPerRowOffset, as: UInt32.self))
            let colorFormat = header.load(fromByteOffset: Self.colorFormatOffset, as: UInt32.self)
            let chromaCount = chromaHeight * chromaBytesPerRow
            var chroma: Data?
            if colorFormat != 0, chromaWidth > 0, chromaCount > 0, byteCount + chromaCount <= Self.slotCapacity {
                chroma = Data(bytes: slotData(slot) + byteCount, count: chromaCount)
            }
            fence()
            let after = header.load(fromByteOffset: Self.seqOffset, as: UInt64.self)
            guard before == after else { continue }

            return CapturedFrame(width: width, height: height, bytesPerRow: bytesPerRow, orientation: orientation,
                                 timestamp: timestamp, sequence: count, pixels: pixels,
                                 colorFormat: chroma == nil ? 0 : colorFormat, chromaWidth: chromaWidth,
                                 chromaHeight: chromaHeight, chromaBytesPerRow: chromaBytesPerRow, chroma: chroma)
        }
        return nil
    }
}
