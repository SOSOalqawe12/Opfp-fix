import SwiftUI

struct HelpView: View {
    var body: some View {
        List {
            Section("Quick start") {
                Step(number: 1, text: "Pick the language on screen (From) and your language (To). Download them if asked.")
                Step(number: 2, text: "Tap “Start translating”, choose FloatLingo, then Start Broadcast.")
                Step(number: 3, text: "Open your game or app. The floating window appears and shows translations live.")
                Step(number: 4, text: "Move the window where it doesn't cover what you need. Pinch it to resize, swipe it to the side to hide it.")
            }

            Section("Tips for games") {
                Text("Set From to the game's language (for example Chinese) instead of Auto-detect — recognition is faster and more accurate.")
                Text("Tap “Game dialogue” on the main screen: it reads only the bottom third, shows just the dialogue and turns off language correction.")
                Text("Reading a smaller area is the biggest speed boost. Use a custom area around the dialogue box if it isn't at the bottom.")
                Text("Use the floating window's ❚❚ button to freeze a translation while you read it.")
            }

            Section("Why a floating video window?") {
                Text("Android lets apps draw see-through overlays on top of other apps. iOS and iPadOS don't allow that for any app. Picture in Picture is the only window that floats above every app, so FloatLingo draws the translations into it.")
                Text("The screen capture also sees the floating window. FloatLingo ignores its own translations, but reading only part of the screen and keeping the window outside that area works best.")
            }

            Section("Privacy") {
                Text("Text recognition (Vision) and translation (Apple Translation) run on this device. Screen frames are kept only in memory and in one temporary file inside the app, and are never uploaded.")
                Text("Apps that block screen recording (some video and banking apps) show up black and can't be translated.")
            }

            Section("iPad") {
                Text("On iPad you can also open FloatLingo in a window next to your app and use the large live view.")
            }
        }
        .navigationTitle("How it works")
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.2), in: Circle())
            Text(text)
        }
    }
}
