import SwiftUI

/// Full-screen view of the game/app exactly as it looked, with every piece of text replaced in
/// place by its translation, in the screen's own colors. Hold anywhere to peek at the original;
/// tap a label to see it larger. Swipe along the bottom edge to jump straight back to the game.
struct TranslatedScreenView: View {
    let screen: TranslatedScreen
    var onClose: () -> Void

    @State private var showOriginal = false
    @State private var selected: TranslatedScreen.Label?

    var body: some View {
        GeometryReader { proxy in
            let frame = fittedRect(for: screen.image.size, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: screen.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

                if !showOriginal {
                    ForEach(screen.labels) { label in
                        TranslationLabelView(label: label, frame: frame, rtl: screen.isRightToLeft)
                            .onTapGesture { selected = label }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                showOriginal = pressing
            })
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { toolbar }
        .statusBarHidden()
        .sheet(item: $selected) { label in
            LabelDetailView(label: label, rtl: screen.isRightToLeft)
                .presentationDetents([.medium])
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(showOriginal ? "Original" : (screen.labels.isEmpty ? "No text found on this screen" : "Hold to see the original"))
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(screen.capturedAt, style: .relative)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                onClose()
            } label: {
                Image(systemName: "gearshape.fill")
                    .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .opacity(0.9)
    }

    private func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// One translation sitting exactly where the original text was.
private struct TranslationLabelView: View {
    let label: TranslatedScreen.Label
    let frame: CGRect
    let rtl: Bool

    var body: some View {
        let rect = CGRect(x: frame.minX + label.rect.minX * frame.width,
                          y: frame.minY + label.rect.minY * frame.height,
                          width: label.rect.width * frame.width,
                          height: label.rect.height * frame.height)
        let lineHeight = rect.height / CGFloat(max(label.lineCount, 1))
        // Translations are often longer than the original (e.g. Chinese → English): let the label
        // grow a little and shrink the text to fit rather than spill over its neighbours.
        let width = max(rect.width + 8, 44)
        let height = max(rect.height + 4, 18)
        Text(label.translation ?? label.original)
            .font(.system(size: max(11, lineHeight * 0.85), weight: .semibold))
            .minimumScaleFactor(0.35)
            .lineLimit(max(label.lineCount, 1) + 1)
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .foregroundStyle(Color(uiColor: label.foreground))
            .padding(.horizontal, 3)
            .frame(width: width, height: height, alignment: rtl ? .trailing : .leading)
            .background(Color(uiColor: label.background), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .position(x: rect.minX - 4 + width / 2, y: rect.midY)
    }
}

private struct LabelDetailView: View {
    let label: TranslatedScreen.Label
    let rtl: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(label.translation ?? "Not translated yet")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .textSelection(.enabled)
            Text(label.original)
                .font(.title3)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(24)
    }
}
