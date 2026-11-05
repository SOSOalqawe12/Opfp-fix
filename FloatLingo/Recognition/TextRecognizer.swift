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
}

struct RecognitionConfig {
    /// Vision language codes; empty = let Vision detect the language.
    var languages: [String]
    var languageCorrection: Bool
    var smallText: Bool
    /// Normalized area of the upright frame to read, origin top-left.
    var region: CGRect
    var rotation: RotationOverride
}

struct RecognitionResult {
    var blocks: [TextBlock]
    /// width / height of the region that was read, in pixels.
    var regionAspect: CGFloat
    var frameTimestamp: Double
    var frameSequence: UInt64
    var duration: TimeInterval
}

enum TextRecognizer {
    static func recognize(_ frame: CapturedFrame, config: RecognitionConfig) throws -> RecognitionResult? {
        let started = Date()
        guard let raw = grayImage(from: frame) else { return nil }

        let orientation: CGImagePropertyOrientation
        switch config.rotation {
        case .automatic: orientation = CGImagePropertyOrientation(rawValue: frame.orientation) ?? .up
        case .none: orientation = .up
        case .clockwise90: orientation = .right
        case .upsideDown: orientation = .down
        case .counterClockwise90: orientation = .left
        }
        guard let upright = rotate(raw, to: orientation) else { return nil }

        let width = CGFloat(upright.width), height = CGFloat(upright.height)
        let region = config.region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropRect = CGRect(x: region.minX * width, y: region.minY * height,
                              width: region.width * width, height: region.height * height).integral
        guard let image = upright.cropping(to: cropRect), image.width > 8, image.height > 8 else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = config.languageCorrection
        if config.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = config.languages
        }
        // Game and app UI text is often tiny compared to the whole screen.
        request.minimumTextHeight = config.smallText ? 0.008 : 0.02

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let pixelWidth = CGFloat(image.width), pixelHeight = CGFloat(image.height)
        let lines: [Line] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox // normalized, origin bottom-left
            let rect = CGRect(x: box.minX * pixelWidth, y: (1 - box.maxY) * pixelHeight,
                              width: box.width * pixelWidth, height: box.height * pixelHeight)
            return Line(text: text, rect: rect, confidence: candidate.confidence)
        }

        let blocks = group(lines).map { block in
            TextBlock(
                text: block.text,
                rect: CGRect(x: block.rect.minX / pixelWidth, y: block.rect.minY / pixelHeight,
                             width: block.rect.width / pixelWidth, height: block.rect.height / pixelHeight),
                confidence: block.confidence
            )
        }
        return RecognitionResult(blocks: blocks, regionAspect: pixelWidth / pixelHeight,
                                 frameTimestamp: frame.timestamp, frameSequence: frame.sequence,
                                 duration: Date().timeIntervalSince(started))
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
