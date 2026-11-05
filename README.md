# FloatLingo: live screen translation for iOS & iPadOS

FloatLingo translates the text in **any app or game** in real time and shows the result in a
**floating window that stays on top of everything**. It's like the Android screen-translator
overlays (for example the ones people use for *One Piece Fighting Path*), built for iPhone and iPad.

- Works in every app: games, social apps, manga readers, websites.
- Supports every language pair Apple's on-device Translation supports (about 20 languages,
  including Chinese (Simplified and Traditional), Arabic, Japanese, Korean, English, Spanish, French,
  German, Russian, Turkish, Thai, Vietnamese, Hindi, Indonesian…). Auto-detect is available too.
- Runs 100% on device. No account, no API key, no internet needed after the languages are downloaded.
- Built for iOS / iPadOS 26 and 27 (deployment target 26.0).

## How it works

```
┌────────────── your game / any app ──────────────┐
│                                                  │      ┌─────────────────────────┐
│   你好，欢迎来到伟大航路！                        │      │  Floating window (PiP)  │
│                                                  │ ───▶ │  مرحباً، أهلاً بك في     │
└──────────────────────────────────────────────────┘      │  الخط العظيم!            │
        │ ReplayKit screen broadcast                      └─────────────────────────┘
        ▼                                                             ▲
  FloatLingoBroadcast (extension)                                     │
  throttle → skip unchanged frames → downscale → shared memory        │
        │ Darwin notification                                         │
        ▼                                                             │
  FloatLingo app (kept alive by Picture in Picture)                   │
  Vision OCR ⇄ (pipelined) ⇄ detect language → Apple Translation ─────┘
```

1. A **Broadcast Upload Extension** receives the screen while capture is on. It looks at up to
   5 frames per second (adjustable 1–8), skips frames whose content didn't change since the
   last frame it sent, keeps only the brightness channel, downsizes it and hands it to the app
   through a shared-memory double buffer (no file is written per frame).
2. The **app** reads the text with Vision, joins the lines into paragraphs, filters out
   numbers, text that is already in your language, and its own floating window. Then it
   translates with `TranslationSession`.
   - Reading the next screen and translating the current one happen at the same time.
   - Translations are cached, and text that differs from a moment ago by only a misread
     character reuses its translation. Repeated text appears instantly and doesn't flicker.

### Speed

Typical delay from text appearing to its translation is estimated at roughly 0.5–1.5 s, depending
on the device, how much of the screen is read, and whether the text was seen before. This hasn't
been measured on a device yet. The real number is shown live in the floating window
(`● Live · 0.6 s`) and in the app. The biggest speed-ups, in order:

1. Choose the exact **From** language instead of Auto-detect.
2. Read only part of the screen (**Dialogue bar** does this in one tap).
3. Leave **More fluent translations** off.
3. The translation is drawn into video frames and played in a **Picture-in-Picture** window.
   You can drag it anywhere, pinch to make it smaller or bigger, or swipe it to the screen edge
   to hide it. Its play/pause button freezes the translation.

### Why not a see-through overlay like on Android?

iOS and iPadOS don't let any app draw over other apps. There is no equivalent of Android's
`SYSTEM_ALERT_WINDOW` or accessibility overlay. Picture in Picture is the only public surface
that floats above every app. FloatLingo makes the most of it:

- **Lens mode** (default): the window shows a dimmed, blurred copy of the screen with each
  translation placed exactly on top of the text it translates, like Google Lens. You can see
  which translation belongs to which button or line. The window takes the shape of the game
  (a wide strip for landscape games).
- **Subtitles bar**: only the translated lines, large, in a slim 3:1 bar. Best for dialogue.
  It stays readable when pinched small.
- **Colors**: dark, black, light, or yellow, with adjustable text size and the option to
  show the original text.
- **Screen area**: read only part of the screen (for example the dialogue box), which is faster
  and keeps the floating window out of the capture.

On iPad you can also open FloatLingo in a window beside the game and use its large live view.

## Install

### Option A: no Mac needed (GitHub Actions + sideloading)

1. In this repository, open **Actions → Build iOS app** and open the latest successful run.
   You can also start one with **Run workflow**.
2. Download the **FloatLingo-ipa** artifact and unzip it to get `FloatLingo.ipa`.
3. Install it with **Sideloadly**, **AltStore** or **SideStore** using your Apple ID. These tools
   re-sign the app and its broadcast extension. FloatLingo reads its App Group from the
   provisioning profile, so it still works when the tool renames it.
   - With a free Apple ID the app expires after 7 days and uses 2 of your 10 weekly App IDs
     (the app plus the extension).
   - Make sure the tool keeps the **App Groups** entitlement and the **PlugIns** folder
     (don't enable options that remove app extensions).

### Option B: Xcode on a Mac

```bash
brew install xcodegen
xcodegen generate
open FloatLingo.xcodeproj
```

1. In `project.yml`, set `BUNDLE_PREFIX`, `FL_APP_GROUP` and `DEVELOPMENT_TEAM` to your own
   values. Also update `AppGroup.defaultIdentifier` in `Shared/AppGroup.swift`.
2. Run `xcodegen generate` again, select your iPhone and press Run. Xcode 26 or 27 is required.

## Use

1. **Languages**: choose *From* (the language on screen, for example Chinese) and *To* (your
   language, for example Arabic). Tap **Download languages** if asked.
2. Pick a one-tap setup:
   - **Chinese game** (for example One Piece Fighting Path): reads Chinese, Lens mode, whole screen.
   - **Dialogue bar**: reads only the bottom third and shows the dialogue in a slim subtitle bar.
   - **Any app**: Lens mode for the whole screen, keeping your chosen languages.
3. Tap **Start translating**, choose *FloatLingo*, then *Start Broadcast*.
   You can also long-press *Screen Recording* in Control Center.
4. Switch to your game. The floating window opens automatically and shows translations live.

### Tips for *One Piece Fighting Path* and other games

- Tap **Chinese game**. It sets *From* to Chinese (Simplified) and uses Lens mode, so every
  menu label and button shows its translation in the right place.
- For story scenes, switch to **Dialogue bar**. It's a much smaller window that shows just the
  dialogue.
- Pinch the floating window down to its smallest size while you play. Pinch it bigger, or tap
  ❚❚, when you want to read a menu.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Broadcast stops immediately with an App Group error | The installer removed the App Groups entitlement. Re-install with App Groups enabled for both the app and the extension. |
| Floating window button is greyed out | Keep FloatLingo open for a second; Picture in Picture needs the preview to be on screen. Check that PiP is on in Settings → General → Picture in Picture. |
| “Download … in FloatLingo” shown in the window | That language isn't installed. Download it in the app, or in Settings → Apps → Translate. |
| Nothing is recognized in landscape | Capture & recognition → *Rotate captured screen*: try 90° options. |
| The app being translated shows up black | It blocks screen recording (DRM video, some banking apps). It can't be translated. |

## Project layout

```
project.yml                     XcodeGen spec (app + broadcast extension)
Config/                         Info.plists and entitlements
Shared/                         Code shared by both targets (App Group, shared-memory frames, signals)
FloatLingoBroadcast/            ReplayKit Broadcast Upload Extension
FloatLingo/App                  App entry, settings, app model
FloatLingo/Recognition          Vision OCR + line grouping
FloatLingo/Translation          Language catalog, detection, TranslationSession engine
FloatLingo/Pipeline             Real-time loop (frame → OCR → filter → translate)
FloatLingo/Overlay              PiP controller and frame renderer
FloatLingo/UI                   SwiftUI screens
.github/workflows/build-ios.yml Builds an installable .ipa on every push
```

---

## بالعربية

**FloatLingo** يترجم النص الظاهر على الشاشة في أي تطبيق أو لعبة (مثل One Piece Fighting Path)
بشكل فوري، ويعرض الترجمة في نافذة عائمة تبقى فوق كل التطبيقات، والترجمة كلها تتم على الجهاز.

ملاحظة مهمة: نظام iOS لا يسمح لأي تطبيق بالرسم بشفافية فوق التطبيقات الأخرى كما في أندرويد،
لذلك تُعرض الترجمة في نافذة «صورة داخل صورة» (PiP) يمكنك تحريكها وتصغيرها وإخفاؤها على حافة الشاشة.

**طريقة الاستخدام:** اختر لغة الشاشة (مثلاً الصينية) ولغتك (العربية) ←
اضغط «Chinese game» ← اضغط «Start translating» واختر FloatLingo ثم Start Broadcast ← افتح اللعبة.
في وضع **Lens** تظهر كل ترجمة فوق الكلمة الأصلية في نسخة مصغّرة من الشاشة، فتعرف أي ترجمة لأي زر.
لتصغير النافذة: قرّبها بإصبعين (pinch)، أو اسحبها إلى حافة الشاشة لإخفائها.

**التثبيت بدون ماك:** من تبويب Actions حمّل ملف FloatLingo.ipa ثم ثبّته عبر Sideloadly أو AltStore.
