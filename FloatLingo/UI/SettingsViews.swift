import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Show as", selection: $model.settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.displayMode == .subtitles {
                    Picker("Bar shape", selection: $model.settings.windowShape) {
                        ForEach(WindowShape.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Only the longest text (dialogue)", isOn: $model.settings.onlyLongestText)
                Toggle("Show original text too", isOn: $model.settings.showOriginal)
            }
            Section("Text") {
                Picker("Colors", selection: $model.settings.theme) {
                    ForEach(OverlayTheme.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Text size: \(Int(model.settings.fontScale * 100))%")
                    Slider(value: $model.settings.fontScale, in: 0.5...1.8, step: 0.05)
                }
            }
            Section {
                Toggle("Show in the Dynamic Island", isOn: $model.settings.dynamicIsland)
                Toggle("Pop up each new line", isOn: $model.settings.popUpNewLines)
                    .disabled(!model.settings.dynamicIsland)
            } header: {
                Text("Dynamic Island & Lock Screen")
            } footer: {
                Text("The newest translated line also appears in the Dynamic Island — long-press it to read the whole line, without any window over your game. “Pop up each new line” opens it briefly for every new line (a banner on iPhones without a Dynamic Island); iOS may limit how often.")
            }
            Section {
                EmptyView()
            } footer: {
                Text("Lens shows a dimmed copy of the screen with each translation on top of its original text, so you can see which translation belongs to which button. Subtitles shows only the translated lines in a slim bar. iOS doesn't allow see-through windows over other apps, so pinch the floating window small and park it where it doesn't get in the way.")
            }
        }
        .navigationTitle("Floating window style")
    }
}

struct CaptureSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private let fpsOptions: [Double] = [1, 2, 3, 5, 8]

    var body: some View {
        Form {
            Section {
                Picker("Read", selection: $model.settings.region) {
                    ForEach(CaptureRegion.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.region == .custom {
                    RegionSlider(title: "Top", value: $model.settings.customTop)
                    RegionSlider(title: "Bottom", value: $model.settings.customBottom)
                    RegionSlider(title: "Left", value: $model.settings.customLeft)
                    RegionSlider(title: "Right", value: $model.settings.customRight)
                }
            } header: {
                Text("Screen area")
            } footer: {
                Text("Reading only part of the screen is faster and keeps the floating window from being read back. For games, “Bottom third” usually covers the dialogue box.")
            }

            Section {
                Picker("Updates per second", selection: $model.settings.captureFPS) {
                    ForEach(fpsOptions, id: \.self) { fps in
                        Text(fps == 5 ? "5 (recommended)" : "\(Int(fps))").tag(fps)
                    }
                }
                Picker("Quality", selection: $model.settings.captureQuality) {
                    ForEach(CaptureQuality.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Read small text", isOn: $model.settings.smallText)
                Toggle("Language correction", isOn: $model.settings.languageCorrection)
            } header: {
                Text("Speed")
            } footer: {
                Text("Higher is more real-time but uses more battery. Unchanged screens are skipped automatically. Turn off language correction for names, numbers and game terms.")
            }

            Section {
                Toggle("More fluent translations", isOn: $model.settings.preferHighFidelity)
            } header: {
                Text("Translation")
            } footer: {
                Text("Uses the Apple Intelligence translation model when this device has it (iOS 26.4 or later). It's slower than the standard model.")
            }

            Section {
                Picker("Rotate captured screen", selection: $model.settings.rotation) {
                    ForEach(RotationOverride.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Leave on Automatic. Change it only if nothing is recognized while an app is in landscape.")
            }
        }
        .navigationTitle("Capture & recognition")
    }
}

private struct RegionSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value * 100))%")
            Slider(value: $value, in: 0...1, step: 0.01)
        }
    }
}

struct LanguageDownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: LanguageCatalog

    var body: some View {
        List {
            Section {
                ForEach(catalog.options.filter { model.sourceStates[$0.id] != nil }) { option in
                    HStack {
                        LanguageRow(option: option)
                        Spacer()
                        switch model.sourceStates[option.id] {
                        case .ready?:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Downloaded")
                        case .needsDownload?:
                            Button("Get") { model.requestDownload(from: option.language) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        default:
                            Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Auto-detect only translates languages that are downloaded for your target language. You can also manage downloads in Settings → Apps → Translate.")
            }
        }
        .navigationTitle("Source languages")
        .refreshable { await model.refreshPairStatus() }
    }
}

struct LiveTextView: View {
    @EnvironmentObject private var translator: LiveTranslator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: LanguageCatalog

    var body: some View {
        let rtl = catalog.option(id: model.settings.targetLanguageID)?.isRightToLeft ?? false
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if translator.entries.isEmpty {
                    ContentUnavailableView("Nothing to translate yet", systemImage: "text.viewfinder",
                                           description: Text("Tap Start translating and open another app."))
                }
                ForEach(translator.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        if model.settings.showOriginal {
                            Text(entry.original).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(entry.translation ?? entry.original)
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    }
                    .textSelection(.enabled)
                }
            }
            .padding()
        }
        .background(.ultraThinMaterial)
        .navigationTitle("Live")
    }
}
