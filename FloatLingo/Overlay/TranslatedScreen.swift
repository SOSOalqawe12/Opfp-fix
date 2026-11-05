import CoreImage
import CoreVideo
import ImageIO
import UIKit

/// The raw material for a translated screen, kept by `LiveTranslator` for recent frames.
struct ScreenSnapshot {
    var frame: CapturedFrame
    var orientation: CGImagePropertyOrientation
    /// Normalized area that was read, in the upright frame (origin top-left).
    var region: CGRect
    var items: [OverlayItem]
}

/// The game/app screen exactly as it looked, with every piece of text replaced in place by its
/// translation — the closest iOS allows to text floating over each word of another app.
struct TranslatedScreen: Identifiable {
    struct Label: Identifiable {
        let id: Int
        let original: String
        let translation: String?
        /// Normalized rect in the upright image, origin top-left.
        let rect: CGRect
        let lineCount: Int
        /// Average color under the original text, so the label blends into the screen.
        let background: UIColor
        let foreground: UIColor
    }

    let id = UUID()
    let image: UIImage
    let labels: [Label]
    let isRightToLeft: Bool
    let capturedAt: Date
}

enum TranslatedScreenBuilder {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func build(from snapshot: ScreenSnapshot, isRightToLeft: Bool) -> TranslatedScreen? {
        guard let raw = colorImage(of: snapshot.frame) else { return nil }

        // Draw it upright (games are usually landscape; the capture may be stored rotated).
        let rotated = UIImage(cgImage: raw, scale: 1, orientation: uiOrientation(snapshot.orientation))
        let size = rotated.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            rotated.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let pixels = upright.cgImage else { return nil }

        let region = snapshot.region
        let labels = snapshot.items.enumerated().map { index, item -> TranslatedScreen.Label in
            let rect = CGRect(x: region.minX + item.rect.minX * region.width,
                              y: region.minY + item.rect.minY * region.height,
                              width: item.rect.width * region.width,
                              height: item.rect.height * region.height)
            let pixelRect = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                                   width: rect.width * size.width, height: rect.height * size.height)
            let colors = labelColors(in: pixels, around: pixelRect)
            return TranslatedScreen.Label(id: index, original: item.original, translation: item.translation,
                                          rect: rect, lineCount: item.lineCount,
                                          background: colors.background, foreground: colors.foreground)
        }
        return TranslatedScreen(image: upright, labels: labels, isRightToLeft: isRightToLeft,
                                capturedAt: Date(timeIntervalSince1970: snapshot.frame.timestamp))
    }

    // MARK: - Pixels

    /// Rebuilds a color image from the luma + CbCr planes (gray when there is no color plane).
    static func colorImage(of frame: CapturedFrame) -> CGImage? {
        if let chroma = frame.chroma,
           let format = FrameColorFormat(rawValue: frame.colorFormat), format != .grayOnly,
           let image = yuvImage(frame: frame, chroma: chroma, fullRange: format == .fullRange420) {
            return image
        }
        guard let provider = CGDataProvider(data: frame.pixels as CFData) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func yuvImage(frame: CapturedFrame, chroma: Data, fullRange: Bool) -> CGImage? {
        let type = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, type, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let copied: Bool = frame.pixels.withUnsafeBytes { luma in
            chroma.withUnsafeBytes { color in
                guard let lumaSource = luma.baseAddress, let colorSource = color.baseAddress,
                      let lumaDestination = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                      let colorDestination = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
                else { return false }
                let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                for row in 0..<min(frame.height, CVPixelBufferGetHeightOfPlane(buffer, 0)) {
                    memcpy(lumaDestination + row * lumaRowBytes, lumaSource + row * frame.bytesPerRow,
                           min(frame.width, lumaRowBytes))
                }
                let colorRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                let rows = min(frame.chromaHeight, CVPixelBufferGetHeightOfPlane(buffer, 1))
                for row in 0..<rows {
                    memcpy(colorDestination + row * colorRowBytes, colorSource + row * frame.chromaBytesPerRow,
                           min(frame.chromaWidth * 2, colorRowBytes, frame.chromaBytesPerRow))
                }
                return true
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard copied else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(image, from: image.extent)
    }

    /// Average color of the area under the text, and a readable text color on top of it.
    private static func labelColors(in image: CGImage, around rect: CGRect) -> (background: UIColor, foreground: UIColor) {
        let fallback = (UIColor(white: 0.08, alpha: 0.9), UIColor.white)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = rect.insetBy(dx: -2, dy: -2).integral.intersection(bounds)
        guard !area.isEmpty, let cropped = image.cropping(to: area) else { return fallback }

        let side = 8
        var samples = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = samples.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return fallback }

        var red = 0.0, green = 0.0, blue = 0.0
        for index in stride(from: 0, to: samples.count, by: 4) {
            red += Double(samples[index]); green += Double(samples[index + 1]); blue += Double(samples[index + 2])
        }
        let count = Double(side * side) * 255
        red /= count; green /= count; blue /= count
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        let background = UIColor(red: red, green: green, blue: blue, alpha: 0.94)
        return (background, luminance > 0.55 ? UIColor(white: 0.05, alpha: 1) : .white)
    }

    private static func uiOrientation(_ orientation: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
