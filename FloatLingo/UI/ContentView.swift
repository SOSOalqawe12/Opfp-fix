import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var floating: FloatingWindowController
    @EnvironmentObject private var translator: LiveTranslator
    @EnvironmentObject private var catalog: LanguageCatalog

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FloatingPreview()
                Form {
                    startSection
                    statusSection
                    languageSection
                    floatingSection
                    captureSection
                    liveSection
                    Section {
                        NavigationLink { AppearanceSettingsView() } label: {
                            Label("Floating window style", systemImage: "textformat.size")
                        }
                        NavigationLink { CaptureSettingsView() } label: {
                            Label("Capture & recognition", systemImage: "viewfinder")
                        }
                        NavigationLink { HelpView() } label: {
                            Label("How it works", systemImage: "questionmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("FloatLingo")
            .navigationBarTitleDisplayMode(.inline)
        }
        .translationTask(model.downloadConfiguration) { session in
            await model.performDownload(using: session)
        }
    }

    // MARK: Sections

    private var startSection: some View {
        Section {
            Button {
                model.startOrStopTranslating()
            } label: {
                Label(model.isBroadcasting ? "Stop translating" : "Start translating",
                      systemImage: model.isBroadcasting ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isBroadcasting ? Color.red : Color.accentColor)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            HStack(spacing: 10) {
                ForEach(QuickSetup.allCases) { setup in
                    let active = setup.isApplied(in: model.settings)
                    Button {
                        model.apply(setup)
                    } label: {
                        Label(setup.title, systemImage: active ? "checkmark" : setup.systemImage)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(active ? Color.accentColor : Color.secondary)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
        } footer: {
            Text(model.isBroadcasting
                 ? "Translating. Switch to your game or app — the floating window follows you."
                 : "Pick “FloatLingo” → Start Broadcast, then switch to your game or app.")
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                StatusPill(title: "Capture", isOn: model.isBroadcasting, systemImage: "record.circle")
                StatusPill(title: "Floating", isOn: floating.isActive, systemImage: "pip")
                Spacer(minLength: 0)
                if let latency = translator.lastLatency, model.isBroadcasting {
                    Text("\(Int(latency * 1000)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let error = translator.lastError ?? floating.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var languageSection: some View {
        Section {
            Picker("From", selection: $model.settings.sourceLanguageID) {
                Text("Auto-detect").tag(String?.none)
                ForEach(catalog.options) { option in
                    LanguageRow(option: option).tag(Optional(option.id))
                }
            }
            .pickerStyle(.navigationLink)

            Picker("To", selection: $model.settings.targetLanguageID) {
                ForEach(catalog.options) { option in
                    LanguageRow(option: option).tag(option.id)
                }
            }
            .pickerStyle(.navigationLink)

            if model.settings.sourceLanguageID != nil {
                Button {
                    model.swapLanguages()
                } label: {
                    Label("Swap languages", systemImage: "arrow.up.arrow.down")
                }
            }
            pairStatusRow
        } header: {
            Text("1 · Languages")
        } footer: {
            Text("Translation runs fully on device with Apple's Translation framework. Pick the exact source language (for example Chinese for Chinese games) for the best text recognition.")
        }
    }

    @ViewBuilder
    private var pairStatusRow: some View {
        switch model.pairStatus {
        case .unknown:
            if !catalog.isLoaded { ProgressView("Loading languages…") }
        case .ready:
            Label("Ready — works offline", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsDownload:
            Button {
                if let source = model.sourceLanguage { model.requestDownload(from: source) }
            } label: {
                Label("Download languages (required)", systemImage: "arrow.down.circle.fill")
            }
        case .unsupported:
            Label("This language pair isn't supported", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        case .sameLanguage:
            Label("Choose two different languages", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .autoDetect(let installed, let total):
            NavigationLink {
                LanguageDownloadsView()
            } label: {
                LabeledContent("Downloaded source languages", value: "\(installed) of \(total)")
            }
        }
        if let error = model.downloadError {
            Text(error).font(.footnote).foregroundStyle(.red)
        }
    }

    private var floatingSection: some View {
        Section {
            Button {
                floating.isActive ? floating.stop() : floating.start()
            } label: {
                Label(floating.isActive ? "Close floating window" : "Open floating window",
                      systemImage: floating.isActive ? "pip.exit" : "pip.enter")
            }
            .disabled(!floating.isActive && !floating.isPossible)

            Toggle("Open automatically when I switch apps", isOn: $model.settings.autoStartFloatingWindow)

            if floating.isPaused {
                Button {
                    floating.setPaused(false)
                } label: {
                    Label("Resume translating", systemImage: "play.fill")
                }
            }
        } header: {
            Text("2 · Floating window")
        } footer: {
            Text("The floating window stays on top of every app. Drag it anywhere, pinch to resize, or swipe it to the edge to hide it. Its ❚❚ button pauses translation.")
        }
    }

    private var captureSection: some View {
        Section {
            HStack {
                Label(model.isBroadcasting ? "Screen capture is on" : "Screen capture is off",
                      systemImage: model.isBroadcasting ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(model.isBroadcasting ? Color.red : Color.secondary)
                Spacer()
                BroadcastPickerHost(picker: model.broadcast.picker)
                    .frame(width: 36, height: 36)
            }
        } header: {
            Text("3 · Screen capture")
        } footer: {
            Text("FloatLingo reads the text on screen to translate it; nothing is recorded or uploaded. If the Start button doesn't open the broadcast sheet, tap the round icon, or long-press Screen Recording in Control Center.")
        }
    }

    @ViewBuilder
    private var liveSection: some View {
        if !translator.entries.isEmpty {
            Section {
                ForEach(translator.entries.prefix(8)) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.original)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.translation ?? "Download \(entry.sourceName) to translate")
                            .font(.body.weight(.medium))
                            .foregroundStyle(entry.translation == nil ? .secondary : .primary)
                    }
                    .textSelection(.enabled)
                }
                NavigationLink { LiveTextView() } label: {
                    Label("Large live view", systemImage: "rectangle.expand.vertical")
                }
            } header: {
                Text("On screen now")
            }
        }
    }
}

// MARK: - Components

struct FloatingPreview: View {
    @EnvironmentObject private var floating: FloatingWindowController
    @EnvironmentObject private var translator: LiveTranslator

    var body: some View {
        ZStack {
            SampleBufferHost(view: floating.view)
            if floating.isActive {
                Label("Floating window is open", systemImage: "pip")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .aspectRatio(translator.previewAspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 170)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityLabel("Floating window preview")
    }
}

struct StatusPill: View {
    let title: String
    let isOn: Bool
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .background(isOn ? Color.green : Color.secondary.opacity(0.15), in: Capsule())
            .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct LanguageRow: View {
    let option: LanguageOption

    var body: some View {
        HStack {
            Text(option.name)
            if option.nativeName != option.name {
                Text(option.nativeName).foregroundStyle(.secondary)
            }
        }
    }
}

struct SampleBufferHost: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct BroadcastPickerHost: UIViewRepresentable {
    let picker: UIView
    func makeUIView(context: Context) -> UIView { picker }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
