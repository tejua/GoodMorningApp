# Good Morning App

A SwiftUI macOS **Translator** app: a full-body animated girl fills the window, listens while you talk, and speaks the translation back. Use the palette button (top right) to pick background and text colours (saved between launches). The window is freely resizable and supports macOS full screen (green button or ⌃⌘F).

(The app is still called **Good Morning.app**. Earlier versions showed a time-based greeting, your Mac's name and a clock; from v1.4 the Mac app is just the translator. The iOS app below still has them.)

## Voice translate (Mac)

At the bottom of the window, choose **From** and **To** languages (swap them with ⇄), then tap the big mic (or press Space) and talk. Supported languages: English, Hindi, Spanish, French, German, Japanese, Chinese, Arabic, Portuguese and Korean. Your choices are saved.

Recording stops by itself after 2 seconds of silence (or tap stop / press Space any time); if nothing is heard for 8 seconds it stops without translating. What you said appears in a speech bubble on one side of her; the translation appears in her speech bubble on the other side and is spoken aloud with a voice for the target language. Use **Replay** to hear it again.

### Animated avatar (Mac)

A full-body cartoon girl, drawn entirely in SwiftUI, reacts to what's happening:

- **Idle:** breathes, sways gently, blinks and smiles.
- **Listening:** cups a hand to her ear, tilts her head, shows sound waves that follow your mic level, and nods as words come in.
- **Thinking:** rests her hand under her chin and glances up while a thought bubble animates.
- **Speaking:** lip-syncs to the spoken translation, gestures with her hands, and highlights the current word in her speech bubble.
- **Problem** (for example, permission denied): looks a little concerned with her hands clasped.

Turn her off or on with the **Avatar** switch at the top. Her animation pauses when the window is hidden.

### Live mode (Mac)

Turn on the **Live** switch next to the mic for sentence-by-sentence translation while you keep talking. Tap the mic (or press Space) once and it keeps listening until you tap Stop or press Space again:

- The translation box updates live as you speak.
- After a short pause (about 1 second) the sentence is finished, translated and spoken, then it listens for the next one.
- Every sentence is added to **History** (button next to the mic; newest at the bottom) with its translation and a replay button. **Clear** empties it; it keeps the last 50.
- While a translation is being spoken, the mic input is ignored so the Mac doesn't translate its own voice. Headphones work best, especially in a quiet room with loud speakers.

With Live off, it works as before: speak once, it stops after 2 seconds of silence, translates and speaks.

It uses Apple frameworks only, so it's fast and needs no API keys:

- **Speech** + **AVAudioEngine** for live transcription (on-device when the language is downloaded, otherwise Apple's speech servers)
- **Translation** for on-device translation
- **AVSpeechSynthesizer** for spoken playback in the target language

On first use macOS asks for **Microphone** and **Speech Recognition** access. The first translation for a language pair may ask you to download its language packs (also in System Settings › General › Language & Region › Translation Languages); after that translation works offline. For on-device speech recognition in languages other than English and Hindi, add them under System Settings › Keyboard › Dictation; until then those languages use Apple's servers.

## Build

```bash
./build.sh
```

This compiles `main.swift` and `AvatarView.swift` with `swiftc` into `~/Desktop/Good Morning.app` and opens it. Requires macOS 15+ and Xcode command line tools.

## iPhone / iPad (iOS) app

The `iOS/` folder has an iOS version with the earlier (v1.2) feature set: time-based greeting, device name, live clock and date, background and text colour pickers, and English ⇄ Hindi voice translate with 2-second silence auto-stop.

1. Open `iOS/GoodMorning.xcodeproj` in Xcode.
2. Select the **GoodMorning** target › **Signing & Capabilities** and pick your Team (automatic signing).
3. Plug in your iPhone, select it as the run destination and press **Run**. The first time, you may need to trust the developer in Settings › General › VPN & Device Management.

Requires **iOS 18+** (the Translation framework needs it). On first use iOS asks for **Microphone** and **Speech Recognition** access, and the first translation may ask to download the English/Hindi language packs.

Note: since iOS 16, apps see a generic device name (for example "iPhone") instead of your phone's personal name, unless Apple grants a special entitlement.

The Xcode project is generated from `iOS/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`cd iOS && xcodegen generate`), but the generated project is committed, so you don't need XcodeGen to build.
