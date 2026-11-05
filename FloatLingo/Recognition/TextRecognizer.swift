import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A paragraph-ish group of recognized lines.
struct TextBlock: Hashable {
    var text: String
    /// Normalized rect inside the captured region, origin top-left.
    var rect: CGRect
    var confidence: Float
    var lineCount: Int
}

struct RecognitionResult {
    var blocks: [TextBlock]
    /// width / height of the region that was read, in pixels.
    var regionAspect: CGFloat
    var frameTimestamp: Double
    var frameSequence: UInt64
    var duration: TimeInterval
    /// Low-resolution copy of the region that was read, used as the Lens background.
    /// It is deliberately too small for its own text to be read back by OCR.
    var preview: CGImage?
}

struct RecognitionConfig: Equatable {
    /// Vision language codes; empty = let Vision detect the language.
    var languages: [String]
    var languageCorrection: Bool
    var smallText: Bool
    /// Normalized area of the upright frame to read, origin top-left.
    var region: CGRect
    var rotation: RotationOverride
}

/// Reads the text in screen frames with Vision.
///
/// To stay close to real time it is incremental: it remembers the lines it found last time and
/// a small thumbnail of that frame. When only part of the screen changed (a new dialogue line,
/// a menu label), only that part — plus any line it touches — is read again. When nothing
/// changed, Vision isn't run at all. A full read still happens regularly to stay accurate.
final class TextRecognizer: @unchecked Sendable {
    private let lock = NSLock()
    private var previousConfig: RecognitionConfig?
    private var previousSize: CGSize = .zero
    private var previousThumbnail: [UInt8] = []
    private var previousLines: [Line] = []
    private var lastFullPass = Date.distantPast

    private static let thumbnailSide = 96
    private static let fullPassInterval: TimeInterval = 2.5

    func reset() {
        lock.lock(); defer { lock.unlock() }
        previousConfig = nil
        previousLines = []
        previousThumbnail = []
    }

    func recognize(_ frame: CapturedFrame, config: RecognitionConfig) throws -> RecognitionResult? {
        lock.lock(); defer { lock.unlock() }
        let started = Date()
        guard let raw = Self.grayImage(from: frame) else { return nil }

        let orientation: CGImagePropertyOrientation
        switch config.rotation {
        case .automatic: orientation = CGImagePropertyOrientation(rawValue: frame.orientation) ?? .up
        case .none: orientation = .up
        case .clockwise90: orientation = .right
        case .upsideDown: orientation = .down
        case .counterClockwise90: orientation = .left
        }
        guard let upright = Self.rotate(raw, to: orientation) else { return nil }

        let width = CGFloat(upright.width), height = CGFloat(upright.height)
        let region = config.region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropRect = CGRect(x: region.minX * width, y: region.minY * height,
                              width: region.width * width, height: region.height * height).integral
        guard let image = upright.cropping(to: cropRect), image.width > 8, image.height > 8 else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let thumbnail = Self.thumbnail(of: image)

        // Decide how much of the image to read.
        var readRect: CGRect? = CGRect(origin: .zero, size: size) // nil = nothing changed
        let canBeIncremental = previousConfig == config && previousSize == size
            && previousThumbnail.count == thumbnail.count
            && started.timeIntervalSince(lastFullPass) < Self.fullPassInterval
        if canBeIncremental {
            readRect = changedArea(from: previousThumbnail, to: thumbnail, size: size)
        }

        var lines: [Line]
        switch readRect {
        case nil:
            lines = previousLines // nothing changed: reuse what we read last time
        case let rect? where rect.width * rect.height >= size.width * size.height * 0.55:
            lines = try Self.readLines(in: image, area: nil, config: config)
            lastFullPass = started
        case let rect?:
            let kept = previousLines.filter { !$0.rect.intersects(rect) }
            let fresh = try Self.readLines(in: image, area: rect, config: config)
            lines = kept + fresh
        }

        previousConfig = config
        previousSize = size
        previousThumbnail = thumbnail
        previousLines = lines

        let blocks = Self.group(lines).map { block in
            TextBlock(
                text: block.text,
                rect: CGRect(x: block.rect.minX / size.width, y: block.rect.minY / size.height,
                             width: block.rect.width / size.width, height: block.rect.height / size.height),
                confidence: block.confidence,
                lineCount: block.lines.count
            )
        }
        return RecognitionResult(blocks: blocks, regionAspect: size.width / size.height,
                                 frameTimestamp: frame.timestamp, frameSequence: frame.sequence,
                                 duration: Date().timeIntervalSince(started),
                                 preview: Self.makePreview(of: image))
    }

    /// The pixel area that changed since the previous thumbnail (grown to cover every previous
    /// line it touches, so those lines are re-read whole), `nil` when nothing changed, or the
    /// full image when the change is too spread out.
    private func changedArea(from old: [UInt8], to new: [UInt8], size: CGSize) -> CGRect? {
        let side = Self.thumbnailSide
        var minX = side, minY = side, maxX = -1, maxY = -1
        var changedCells = 0
        for y in 0..<side {
            for x in 0..<side where abs(Int(new[y * side + x]) - Int(old[y * side + x])) > 16 {
                changedCells += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard changedCells > 0 else { return nil }
        let full = CGRect(origin: .zero, size: size)
        if changedCells > side * side / 3 { return full }

        let cellWidth = size.width / CGFloat(side), cellHeight = size.height / CGFloat(side)
        var rect = CGRect(x: CGFloat(minX - 1) * cellWidth, y: CGFloat(minY - 1) * cellHeight,
                          width: CGFloat(maxX - minX + 3) * cellWidth, height: CGFloat(maxY - minY + 3) * cellHeight)
        // Lines that overlap the change are read again in full.
        for _ in 0..<2 {
            for line in previousLines where line.rect.intersects(rect) {
                rect = rect.union(line.rect)
            }
        }
        // A little margin so text touching the edge of the change isn't cut.
        let margin = max(cellHeight * 2, 12)
        return rect.insetBy(dx: -margin * 2, dy: -margin).intersection(full).integral
    }

    // MARK: - Vision

    private static func readLines(in image: CGImage, area: CGRect?, config: RecognitionConfig) throws -> [Line] {
        let fullHeight = CGFloat(image.height)
        var source = image
        var origin = CGPoint.zero
        if let area, let cropped = image.cropping(to: area), cropped.width > 8, cropped.height > 8 {
            source = cropped
            origin = area.origin
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = config.languageCorrection
        if config.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = config.languages
        }
        // Game and app UI text is often tiny compared to the whole screen. The minimum is
        // relative to the image Vision sees, so scale it when reading only part of the screen.
        let minimum: CGFloat = config.smallText ? 0.008 : 0.02
        request.minimumTextHeight = Float(min(1, minimum * fullHeight / CGFloat(source.height)))

        let handler = VNImageRequestHandler(cgImage: source, orientation: .up, options: [:])
        try handler.perform([request])

        let width = CGFloat(source.width), height = CGFloat(source.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox // normalized, origin bottom-left
            let rect = CGRect(x: origin.x + box.minX * width, y: origin.y + (1 - box.maxY) * height,
                              width: box.width * width, height: box.height * height)
            return Line(text: text, rect: rect, confidence: candidate.confidence)
        }
    }

    private static func thumbnail(of image: CGImage) -> [UInt8] {
        let side = thumbnailSide
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    // MARK: - Grouping lines into blocks

    private struct Line {
        var text: String
        var rect: CGRect // pixels, origin top-left
        var confidence: Float
    }

    private struct Block {
        var lines: [Line]
        var rect: CGRect
        var text: String {
            var result = ""
            for line in lines {
                if let last = result.unicodeScalars.last, let first = line.text.unicodeScalars.first {
                    result += (TextRecognizer.isUnspaced(last) && TextRecognizer.isUnspaced(first)) ? "" : " "
                }
                result += line.text
            }
            return result
        }
        var confidence: Float {
            lines.map(\.confidence).reduce(0, +) / Float(max(lines.count, 1))
        }
    }

    /// Scripts written without spaces between words (Chinese, Japanese).
    private static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch LanguageDetector.script(of: scalar) {
        case .han?, .kana?: return true
        default: return scalar.properties.generalCategory == .otherPunctuation && scalar.value > 0x2E7F
        }
    }

    private static func group(_ lines: [Line]) -> [Block] {
        var blocks: [Block] = []
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            let target = blocks.lastIndex { block in
                guard let last = block.lines.last else { return false }
                let lineHeight = max(line.rect.height, last.rect.height)
                let gap = line.rect.minY - last.rect.maxY
                let ratio = line.rect.height / max(last.rect.height, 1)
                let overlap = min(block.rect.maxX, line.rect.maxX) - max(block.rect.minX, line.rect.minX)
                let leftAligned = abs(line.rect.minX - block.rect.minX) < lineHeight * 2
                let centered = abs(line.rect.midX - block.rect.midX) < lineHeight * 2
                return gap > -lineHeight * 0.4 && gap < lineHeight * 0.9
                    && ratio > 0.6 && ratio < 1.65
                    && overlap > 0 && (leftAligned || centered)
            }
            if let target {
                blocks[target].lines.append(line)
                blocks[target].rect = blocks[target].rect.union(line.rect)
            } else {
                blocks.append(Block(lines: [line], rect: line.rect))
            }
        }
        return blocks.sorted { a, b in
            abs(a.rect.minY - b.rect.minY) < min(a.rect.height, b.rect.height) * 0.5
                ? a.rect.minX < b.rect.minX
                : a.rect.minY < b.rect.minY
        }
    }

    // MARK: - Image helpers

    private static func makePreview(of image: CGImage) -> CGImage? {
        let scale = min(1, 360 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func grayImage(from frame: CapturedFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData) else { return nil }
        return CGImage(
            width: frame.width, height: frame.height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Applies an EXIF orientation so the returned image is upright.
    private static func rotate(_ image: CGImage, to orientation: CGImagePropertyOrientation) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let quarterTurn: Bool
        switch orientation {
        case .up, .upMirrored: return image
        case .left, .leftMirrored, .right, .rightMirrored: quarterTurn = true
        default: quarterTurn = false
        }
        let size = quarterTurn ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .none

        switch orientation {
        case .right, .rightMirrored: // stored rotated; turn 90° clockwise to display
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        case .left, .leftMirrored: // turn 90° counter-clockwise to display
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        default: // .down
            context.translateBy(x: w, y: h)
            context.rotate(by: .pi)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
