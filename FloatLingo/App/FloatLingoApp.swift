import SwiftUI

@main
struct FloatLingoApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                // Shown on top (not as a full-screen cover) so the floating window's source view
                // stays in the window and Picture in Picture can still start automatically.
                if let screen = model.translatedScreen {
                    TranslatedScreenView(screen: screen) { model.translatedScreen = nil }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.translatedScreen?.id)
            .environmentObject(model)
            .environmentObject(model.floating)
            .environmentObject(model.translator)
            .environmentObject(model.catalog)
            .task { await model.start() }
            .onOpenURL { url in model.openURL(url) }
        }
        .onChange(of: scenePhase) { old, phase in
            switch phase {
            case .active:
                model.appWillComeToFront()
                model.appBecameActive()
            case .inactive where old == .background:
                model.appWillComeToFront()
            case .background:
                model.appWentToBackground()
            default:
                break
            }
        }
    }
}
