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
}

struct OverlayContent {
    var items: [OverlayItem] = []
    /// Small status line drawn in a corner ("● Live · 中文 → العربية").
    var status: String?
    /// Large centered message when there is nothing to show.
    var placeholder: String?
    var regionAspect: CGFloat = 16.0 / 9.0
    var isRightToLeft = false
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
        var card: UIColor
        var text: UIColor
        var secondary: UIColor
        var accent: UIColor
        var shadow: Bool
    }

    private func palette(for theme: OverlayTheme) -> Palette {
        switch theme {
        case .dark:
            return Palette(background: UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
                           card: UIColor(white: 1, alpha: 0.09), text: .white,
                           secondary: UIColor(white: 1, alpha: 0.62),
                           accent: UIColor(red: 0.35, green: 0.85, blue: 0.75, alpha: 1), shadow: true)
        case .black:
            return Palette(background: .black, card: UIColor(white: 1, alpha: 0.12), text: .white,
                           secondary: UIColor(white: 1, alpha: 0.6),
                           accent: UIColor(red: 0.4, green: 0.7, blue: 1, alpha: 1), shadow: true)
        case .light:
            return Palette(background: UIColor(white: 0.97, alpha: 1), card: UIColor(white: 0, alpha: 0.06),
                           text: UIColor(white: 0.05, alpha: 1), secondary: UIColor(white: 0, alpha: 0.5),
                           accent: UIColor(red: 0, green: 0.45, blue: 0.85, alpha: 1), shadow: false)
        case .yellow:
            return Palette(background: .black, card: UIColor(white: 1, alpha: 0.1),
                           text: UIColor(red: 1, green: 0.87, blue: 0.25, alpha: 1),
                           secondary: UIColor(white: 1, alpha: 0.7),
                           accent: UIColor(red: 1, green: 0.87, blue: 0.25, alpha: 1), shadow: true)
        }
    }

    // MARK: - Public

    func makeSampleBuffer(content: OverlayContent, style: OverlayStyle) -> CMSampleBuffer? {
        let size = style.shape.canvasSize(regionAspect: content.regionAspect)
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
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let colors = palette(for: style.theme)
        let canvas = CGRect(origin: .zero, size: size)
        colors.background.setFill()
        UIRectFill(canvas)

        let statusFont = UIFont.systemFont(ofSize: max(16, size.height * 0.04), weight: .medium)
        var body = canvas
        if let status = content.status {
            let statusHeight = statusFont.lineHeight * 1.5
            body.size.height -= statusHeight
            let statusString = NSAttributedString(string: status, attributes: [
                .font: statusFont, .foregroundColor: colors.secondary,
            ])
            let statusSize = statusString.size()
            statusString.draw(at: CGPoint(x: canvas.maxX - statusSize.width - statusFont.lineHeight * 0.8,
                                          y: canvas.maxY - statusHeight + (statusHeight - statusSize.height) / 2))
        }

        if content.items.isEmpty {
            drawPlaceholder(content.placeholder ?? "", in: body, colors: colors, size: size)
            return
        }
        switch style.mode {
        case .subtitles: drawSubtitles(content, style: style, colors: colors, in: body, canvasHeight: size.height)
        case .layout: drawLayout(content, style: style, colors: colors, in: body, canvasHeight: size.height)
        }
    }

    private func drawPlaceholder(_ text: String, in rect: CGRect, colors: Palette, size: CGSize) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: max(20, size.height * 0.065), weight: .semibold),
            .foregroundColor: colors.secondary,
            .paragraphStyle: paragraph,
        ])
        let area = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.1)
        let height = measure(string, width: area.width)
        string.draw(with: CGRect(x: area.minX, y: area.midY - min(height, area.height) / 2,
                                 width: area.width, height: min(height, area.height)),
                    options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
    }

    private func drawSubtitles(_ content: OverlayContent, style: OverlayStyle, colors: Palette, in rect: CGRect, canvasHeight: CGFloat) {
        let inset = max(18, canvasHeight * 0.055)
        let area = rect.insetBy(dx: inset, dy: inset)
        var items = content.items
        var fontSize = min(max(canvasHeight * 0.085 * style.fontScale, 14), 140)
        let minimumFont: CGFloat = 13

        func build() -> [NSAttributedString] {
            items.map { subtitleString(for: $0, fontSize: fontSize, style: style, colors: colors, rtl: content.isRightToLeft) }
        }
        func totalHeight(_ strings: [NSAttributedString]) -> CGFloat {
            strings.reduce(0) { $0 + measure($1, width: area.width) } + CGFloat(max(strings.count - 1, 0)) * fontSize * 0.5
        }

        var strings = build()
        while totalHeight(strings) > area.height && fontSize > minimumFont {
            fontSize = max(minimumFont, fontSize * 0.88)
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
            y += height + fontSize * 0.5
        }
    }

    private func drawLayout(_ content: OverlayContent, style: OverlayStyle, colors: Palette, in rect: CGRect, canvasHeight: CGFloat) {
        let available = rect.insetBy(dx: 8, dy: 8)
        let frame = AVMakeRect(aspectRatio: CGSize(width: max(content.regionAspect, 0.1), height: 1), insideRect: available)
        let outline = UIBezierPath(roundedRect: frame, cornerRadius: 12)
        colors.card.setStroke()
        outline.lineWidth = 2
        outline.stroke()

        for item in content.items {
            let box = CGRect(x: frame.minX + item.rect.minX * frame.width,
                             y: frame.minY + item.rect.minY * frame.height,
                             width: item.rect.width * frame.width,
                             height: item.rect.height * frame.height).insetBy(dx: -4, dy: -3)
            let width = min(max(box.width, 70), frame.maxX - box.minX + 4)
            let maxHeight = max(box.height * 1.8, 24)
            var fontSize = min(max(box.height * 0.8, 10), canvasHeight * 0.09) * style.fontScale
            var string = layoutString(for: item, fontSize: fontSize, colors: colors, rtl: content.isRightToLeft)
            var height = measure(string, width: width - 8)
            while height > maxHeight && fontSize > 8 {
                fontSize *= 0.88
                string = layoutString(for: item, fontSize: fontSize, colors: colors, rtl: content.isRightToLeft)
                height = measure(string, width: width - 8)
            }
            let card = CGRect(x: box.minX, y: box.minY, width: width, height: min(height, maxHeight) + 6)
            let cardColor = colors.background.withAlphaComponent(0.92)
            cardColor.setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 6).fill()
            colors.card.setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 6).fill()
            string.draw(with: card.insetBy(dx: 4, dy: 3),
                        options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        }
    }

    // MARK: - Text

    private func subtitleString(for item: OverlayItem, fontSize: CGFloat, style: OverlayStyle, colors: Palette, rtl: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if style.showOriginal || item.translation == nil {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = .natural
            result.append(NSAttributedString(string: item.original, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize * 0.6, weight: .regular),
                .foregroundColor: colors.secondary,
                .paragraphStyle: paragraph,
            ]))
            if item.translation != nil { result.append(NSAttributedString(string: "\n")) }
        }
        if let translation = item.translation {
            result.append(NSAttributedString(string: translation, attributes: textAttributes(
                font: .systemFont(ofSize: fontSize, weight: .semibold), color: colors.text, colors: colors, rtl: rtl)))
        }
        return result
    }

    private func layoutString(for item: OverlayItem, fontSize: CGFloat, colors: Palette, rtl: Bool) -> NSAttributedString {
        NSAttributedString(string: item.translation ?? item.original, attributes: textAttributes(
            font: .systemFont(ofSize: fontSize, weight: .semibold),
            color: item.translation == nil ? colors.secondary : colors.text, colors: colors, rtl: rtl))
    }

    private func textAttributes(font: UIFont, color: UIColor, colors: Palette, rtl: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if colors.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor(white: 0, alpha: 0.85)
            shadow.shadowOffset = CGSize(width: 0, height: 1.5)
            shadow.shadowBlurRadius = 3
            attributes[.shadow] = shadow
        }
        return attributes
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
