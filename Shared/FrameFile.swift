import Foundation

/// A grayscale (8-bit luma) screen frame handed from the broadcast extension to the app.
struct CapturedFrame {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    /// `CGImagePropertyOrientation` raw value describing how to rotate the pixels to be upright.
    var orientation: UInt32
    /// `Date().timeIntervalSince1970` when the frame was captured.
    var timestamp: Double
    var sequence: UInt64
    var pixels: Data
}

/// Binary file in the App Group container that always holds the most recent frame.
///
/// Layout (little endian):
///   magic u32 | version u32 | width u32 | height u32 | bytesPerRow u32 | orientation u32 |
///   timestamp f64 | sequence u64 | 8 bytes padding | pixels (height * bytesPerRow)
/// The file is replaced atomically, so a reader never sees a half-written frame.
enum FrameFile {
    static let magic: UInt32 = 0x464C_4631 // "FLF1"
    static let version: UInt32 = 1
    static let headerSize = 48

    static var url: URL? {
        AppGroup.containerURL?.appendingPathComponent("latest-frame.bin", isDirectory: false)
    }

    static func write(width: Int, height: Int, bytesPerRow: Int, orientation: UInt32,
                      timestamp: Double, sequence: UInt64, pixels: UnsafeRawBufferPointer) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        var data = Data(capacity: headerSize + pixels.count)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(magic)
        append(version)
        append(UInt32(width))
        append(UInt32(height))
        append(UInt32(bytesPerRow))
        append(orientation)
        append(timestamp.bitPattern)
        append(sequence)
        append(UInt64(0))
        data.append(contentsOf: pixels)
        try data.write(to: url, options: .atomic)
    }

    static func read() -> CapturedFrame? {
        guard let url, let data = try? Data(contentsOf: url), data.count >= headerSize else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
        }
        func u64(_ offset: Int) -> UInt64 {
            UInt64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
        }
        guard u32(0) == magic, u32(4) == version else { return nil }
        let width = Int(u32(8)), height = Int(u32(12)), bytesPerRow = Int(u32(16))
        let byteCount = height * bytesPerRow
        guard width > 0, height > 0, bytesPerRow >= width, data.count >= headerSize + byteCount else { return nil }
        return CapturedFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            orientation: u32(20),
            timestamp: Double(bitPattern: u64(24)),
            sequence: u64(32),
            pixels: data.subdata(in: headerSize..<(headerSize + byteCount))
        )
    }
}
