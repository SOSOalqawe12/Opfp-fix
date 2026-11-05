import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

struct OverlayItem: Hashable {
    var original: String
    /// `nil` while the language pair is unavailable (shown as original text).
    var translation: String?
    /// Normalized rect inside the captured region, origin top-left.
    var rect: CGRect
    var lineCount: Int
}

struct OverlayContent {
    var items: [OverlayItem] = []
    /// Small status pill ("● Live · 0.6 s · 中文 → English").
    var status: String?
    /// Message shown when there is nothing to translate.
    var placeholder: String?
    var regionAspect: CGFloat = 16.0 / 9.0
    var isRightToLeft = false
    /// Low-resolution copy of the captured area (Lens mode background).
    var background: CGImage?
}

struct OverlayStyle {
    var mode: DisplayMode
    var theme: OverlayTheme
    var shape: WindowShape
    var fontScale: CGFloat
    var showOriginal: Bool
}

/// Draws translations into video frames for the Picture-in-Picture floating window.
final class OverlayRenderer {
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    private struct Palette {
        var background: UIColor
        var text: UIColor
        var secondary: UIColor
        var labelFill: UIColor
        var labelText: UIColor
        var pillFill: UIColor
        var shadow: Bool
    }

    private func palette(for theme: OverlayTheme) -> Palette {
        switch theme {
        case .dark:
            return Palette(background: UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1), text: .white,
                           secondary: UIColor(white: 1, alpha: 0.65),
                           labelFill: UIColor(white: 0.98, alpha: 0.96), labelText: UIColor(white: 0.04, alpha: 1),
                           pillFill: UIColor(white: 0, alpha: 0.55), shadow: true)
        case .black:
            return Palette(background: .black, text: .white, secondary: UIColor(white: 1, alpha: 0.6),
                           labelFill: UIColor(white: 0, alpha: 0.88), labelText: .white,
                           pillFill: UIColor(white: 0, alpha: 0.6), shadow: true)
        case .light:
            return Palette(background: UIColor(white: 0.97, alpha: 1), text: UIColor(white: 0.05, alpha: 1),
                           secondary: UIColor(white: 0, alpha: 0.5),
                           labelFill: .white, labelText: UIColor(white: 0.05, alpha: 1),
                           pillFill: UIColor(white: 1, alpha: 0.75), shadow: false)
        case .yellow:
            let yellow = UIColor(red: 1, green: 0.86, blue: 0.2, alpha: 1)
            return Palette(background: .black, text: yellow, secondary: UIColor(white: 1, alpha: 0.7),
                           labelFill: yellow, labelText: .black,
                           pillFill: UIColor(white: 0, alpha: 0.6), shadow: true)
        }
    }

    // MARK: - Public

    func makeSampleBuffer(content: OverlayContent, style: OverlayStyle) -> CMSampleBuffer? {
        let shape = style.mode == .overlay ? WindowShape.matchScreen : style.shape
        let size = shape.canvasSize(regionAspect: content.regionAspect)
        guard let pixelBuffer = makePixelBuffer(size: size) else { return nil }
        draw(content, style: style, into: pixelBuffer, size: size)
        return Self.sampleBuffer(for: pixelBuffer)
    }

    // MARK: - Drawing

    private func draw(_ content: OverlayContent, style: OverlayStyle, into pixelBuffer: CVPixelBuffer, size: CGSize) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // UIKit drawing expects a top-left origin.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let colors = palette(for: style.theme)
        let canvas = CGRect(origin: .zero, size: size)
        colors.background.setFill()
        UIRectFill(canvas)

        switch style.mode {
        case .overlay:
            drawLens(content, style: style, colors: colors, canvas: canvas)
        case .subtitles:
            drawSubtitles(content, style: style, colors: colors, canvas: canvas)
        }
        if let status = content.status {
            drawStatusPill(status, colors: colors, canvas: canvas)
        }
    }

    /// Small rounded status label in the bottom-right corner, kept clear of the PiP window's
    /// rounded corners and truncated instead of running off the edge.
    private func drawStatusPill(_ status: String, colors: Palette, canvas: CGRect) {
        let fontSize = max(15, min(canvas.height * 0.055, canvas.width * 0.028))
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(string: status, attributes: [
            .font: font, .foregroundColor: colors.secondary, .paragraphStyle: paragraph,
        ])
        let inset = max(canvas.width * 0.045, 18)
        let padding = CGSize(width: fontSize * 0.6, height: fontSize * 0.25)
        let maxWidth = canvas.width * 0.7
        let textWidth = min(string.size().width, maxWidth - padding.width * 2)
        let pill = CGRect(x: canvas.maxX - inset - textWidth - padding.width * 2,
                          y: canvas.maxY - inset * 0.6 - font.lineHeight - padding.height * 2,
                          width: textWidth + padding.width * 2,
                          height: font.lineHeight + padding.height * 2)
        colors.pillFill.setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
        string.draw(with: pill.insetBy(dx: padding.width, dy: padding.height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawPlaceholder(_ text: String, in rect: CGRect, colors: Palette, fontSize: CGFloat, onImage: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: onImage ? UIColor.white : colors.secondary,
            .paragraphStyle: paragraph,
        ])
        let area = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.12)
        let height = min(measure(string, width: area.width), area.height)
        let textRect = CGRect(x: area.minX, y: area.midY - height / 2, width: area.width, height: height)
        if onImage {
            UIColor(white: 0, alpha: 0.55).setFill()
            UIBezierPath(roundedRect: textRect.insetBy(dx: -fontSize * 0.6, dy: -fontSize * 0.35),
                         cornerRadius: fontSize * 0.6).fill()
        }
        string.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
    }

    // MARK: Lens

    /// A dimmed, blurred copy of the screen with every translation drawn on top of the text it
    /// translates — so it's obvious which translation belongs to which word or button.
    private func drawLens(_ content: OverlayContent, style: OverlayStyle, colors: Palette, canvas: CGRect) {
        let frame: CGRect
        if let background = content.background {
            frame = AVMakeRect(aspectRatio: CGSize(width: background.width, height: background.height), insideRect: canvas)
            UIImage(cgImage: background).draw(in: frame)
            UIColor(white: 0, alpha: style.theme == .light ? 0.25 : 0.5).setFill()
            UIRectFillUsingBlendMode(frame, .normal)
        } else {
            frame = AVMakeRect(aspectRatio: CGSize(width: max(content.regionAspect, 0.1), height: 1), insideRect: canvas)
        }

        if content.items.isEmpty {
            drawPlaceholder(content.placeholder ?? "", in: frame, colors: colors,
                            fontSize: max(20, canvas.height * 0.07), onImage: content.background != nil)
            return
        }

        let minimumFont = max(14, canvas.height * 0.045) * style.fontScale
        let maximumFont = max(minimumFont, canvas.height * 0.12 * style.fontScale)
        var placed: [CGRect] = []

        for item in content.items {
            let box = CGRect(x: frame.minX + item.rect.minX * frame.width,
                             y: frame.minY + item.rect.minY * frame.height,
                             width: item.rect.width * frame.width,
                             height: item.rect.height * frame.height)
            let lineHeight = box.height / CGFloat(max(item.lineCount, 1))
            var fontSize = min(max(lineHeight * 0.9 * style.fontScale, minimumFont), maximumFont)
            let padding = CGSize(width: max(4, fontSize * 0.3), height: max(2, fontSize * 0.12))

            // Translations are usually longer than the original (e.g. Chinese → English), so
            // the label may grow wider and taller than the original text, within limits.
            let maxWidth = min(max(frame.width * 0.6, box.width), frame.width - 4 - padding.width * 2)
            var width = min(max(box.width, fontSize * 5), maxWidth)
            var string = lensString(for: item, fontSize: fontSize, colors: colors, rtl: content.isRightToLeft)
            var height = measure(string, width: width)
            let maxHeight = max(box.height * 1.7, fontSize * 2.6)
            while height > maxHeight {
                if width < maxWidth {
                    width = min(width * 1.25, maxWidth)
                } else if fontSize > minimumFont {
                    fontSize = max(minimumFont, fontSize * 0.9)
                    string = lensString(for: item, fontSize: fontSize, colors: colors, rtl: content.isRightToLeft)
                } else {
                    break
                }
                height = measure(string, width: width)
            }
            let textWidth = min(width, ceil(string.size().width))
            var label = CGRect(x: box.minX - padding.width, y: box.midY - height / 2 - padding.height,
                               width: textWidth + padding.width * 2, height: min(height, maxHeight) + padding.height * 2)
            // Keep inside the picture.
            label.origin.x = min(max(label.minX, frame.minX + 2), frame.maxX - label.width - 2)
            label.origin.y = min(max(label.minY, frame.minY + 2), frame.maxY - label.height - 2)
            // Don't cover a label that is already there: slide down below it when possible.
            for other in placed where other.intersects(label) {
                let below = other.maxY + 2
                if below + label.height <= frame.maxY - 2 { label.origin.y = below }
            }
            placed.append(label)

            if colors.shadow {
                UIColor(white: 0, alpha: 0.35).setFill()
                UIBezierPath(roundedRect: label.offsetBy(dx: 0, dy: 2), cornerRadius: fontSize * 0.3).fill()
            }
            colors.labelFill.setFill()
            UIBezierPath(roundedRect: label, cornerRadius: fontSize * 0.3).fill()
            string.draw(with: label.insetBy(dx: padding.width, dy: padding.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        }
    }

    private func lensString(for item: OverlayItem, fontSize: CGFloat, colors: Palette, rtl: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        paragraph.lineBreakMode = .byWordWrapping
        let pending = item.translation == nil
        return NSAttributedString(string: item.translation ?? item.original, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: pending ? colors.labelText.withAlphaComponent(0.5) : colors.labelText,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: Subtitles

    private func drawSubtitles(_ content: OverlayContent, style: OverlayStyle, colors: Palette, canvas: CGRect) {
        let statusSpace = content.status == nil ? 0 : max(15, canvas.height * 0.055) * 1.9
        var body = canvas
        body.size.height -= statusSpace
        let inset = max(20, canvas.height * 0.06)
        let area = body.insetBy(dx: max(inset, canvas.width * 0.04), dy: inset)

        if content.items.isEmpty {
            drawPlaceholder(content.placeholder ?? "", in: body, colors: colors,
                            fontSize: max(20, canvas.height * 0.1), onImage: false)
            return
        }

        // Big text first: the window is often pinched small over a game.
        var items = content.items
        var fontSize = min(max(canvas.height * 0.16 * style.fontScale, 16), 150)
        let minimumFont = max(14, canvas.height * 0.065)

        func build() -> [NSAttributedString] {
            items.map { subtitleString(for: $0, fontSize: fontSize, style: style, colors: colors, rtl: content.isRightToLeft) }
        }
        func totalHeight(_ strings: [NSAttributedString]) -> CGFloat {
            strings.reduce(0) { $0 + measure($1, width: area.width) } + CGFloat(max(strings.count - 1, 0)) * fontSize * 0.4
        }

        var strings = build()
        while totalHeight(strings) > area.height && fontSize > minimumFont {
            fontSize = max(minimumFont, fontSize * 0.9)
            strings = build()
        }
        while totalHeight(strings) > area.height && items.count > 1 {
            items.removeFirst()
            strings = build()
        }

        let total = min(totalHeight(strings), area.height)
        var y = area.minY + max(0, (area.height - total) / 2)
        for string in strings {
            let height = min(measure(string, width: area.width), area.maxY - y)
            guard height > 0 else { break }
            string.draw(with: CGRect(x: area.minX, y: y, width: area.width, height: height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
            y += height + fontSize * 0.4
        }
    }

    private func subtitleString(for item: OverlayItem, fontSize: CGFloat, style: OverlayStyle, colors: Palette, rtl: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if style.showOriginal || item.translation == nil {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = .natural
            result.append(NSAttributedString(string: item.original, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize * 0.55, weight: .regular),
                .foregroundColor: colors.secondary,
                .paragraphStyle: paragraph,
            ]))
            if item.translation != nil { result.append(NSAttributedString(string: "\n")) }
        }
        if let translation = item.translation {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
            paragraph.lineBreakMode = .byWordWrapping
            var attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: colors.text,
                .paragraphStyle: paragraph,
            ]
            if colors.shadow {
                let shadow = NSShadow()
                shadow.shadowColor = UIColor(white: 0, alpha: 0.85)
                shadow.shadowOffset = CGSize(width: 0, height: 1.5)
                shadow.shadowBlurRadius = 3
                attributes[.shadow] = shadow
            }
            result.append(NSAttributedString(string: translation, attributes: attributes))
        }
        return result
    }

    private func measure(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        string.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height.rounded(.up)
    }

    // MARK: - Buffers

    private func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private static func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
