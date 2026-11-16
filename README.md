# Good Morning App

A small SwiftUI macOS **Translator** app: speak English or Hindi and an animated girl listens, translates and speaks the translation back. Use the palette button (top right) to pick background and text colours (saved between launches).

(The app is still called **Good Morning.app**. Earlier versions showed a time-based greeting, your Mac's name and a clock; from v1.4 the Mac app is just the translator. The iOS app below still has them.)

## Voice translate (English ⇄ Hindi)

Pick the language you're speaking (English or Hindi), tap the mic (or press Space), and talk. Recording stops by itself after 2 seconds of silence (or tap stop / press Space any time); if nothing is heard for 8 seconds it stops without translating. The app shows a live transcript, translates it into the other language and speaks the translation aloud. Use **Replay** to hear it again.

### Animated avatar (Mac)

A cartoon girl, drawn entirely in SwiftUI, reacts to what's happening:

- **Idle:** breathes gently, blinks and smiles.
- **Listening:** tilts her head, raises her eyebrows, shows sound waves that follow your mic level, and nods as words come in.
- **Thinking:** glances up while a thought bubble animates.
- **Speaking:** lip-syncs to the spoken translation, with a speech bubble that highlights the current word.
- **Problem** (for example, permission denied): looks a little concerned.

Turn her off or on with the **Avatar** switch next to the title. Her animation pauses when the window is hidden.

### Live mode (Mac)

Turn on the **Live** switch next to the language picker for sentence-by-sentence translation while you keep talking. Tap the mic (or press Space) once and it keeps listening until you tap Stop or press Space again:

- The translation box updates live as you speak.
- After a short pause (about 1 second) the sentence is finished, translated and spoken, then it listens for the next one.
- Every sentence is added to a **History** list (newest at the bottom) with its translation and a replay button. **Clear** empties it; it keeps the last 50.
- While a translation is being spoken, the mic input is ignored so the Mac doesn't translate its own voice. Headphones work best, especially in a quiet room with loud speakers.

With Live off, it works as before: speak once, it stops after 2 seconds of silence, translates and speaks.

Everything runs on-device with Apple frameworks, so it's fast and needs no API keys:

- **Speech** + **AVAudioEngine** for live transcription (on-device recognition when available)
- **Translation** for English ⇄ Hindi translation
- **AVSpeechSynthesizer** for spoken playback (Hindi and Indian English voices)

On first use macOS asks for **Microphone** and **Speech Recognition** access. The first translation may ask you to download the English/Hindi language packs (also in System Settings › General › Language & Region › Translation Languages); after that it works offline.

## Build

```bash
./build.sh
```

This compiles `main.swift` and `AvatarView.swift` with `swiftc` into `~/Desktop/Good Morning.app` and opens it. Requires macOS 15+ and Xcode command line tools.

## iPhone / iPad (iOS) app

The `iOS/` folder has an iOS version with the same features: time-based greeting, device name, live clock and date, background and text colour pickers, and English ⇄ Hindi voice translate with 2-second silence auto-stop.

1. Open `iOS/GoodMorning.xcodeproj` in Xcode.
2. Select the **GoodMorning** target › **Signing & Capabilities** and pick your Team (automatic signing).
3. Plug in your iPhone, select it as the run destination and press **Run**. The first time, you may need to trust the developer in Settings › General › VPN & Device Management.

Requires **iOS 18+** (the Translation framework needs it). On first use iOS asks for **Microphone** and **Speech Recognition** access, and the first translation may ask to download the English/Hindi language packs.

Note: since iOS 16, apps see a generic device name (for example "iPhone") instead of your phone's personal name, unless Apple grants a special entitlement.

The Xcode project is generated from `iOS/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`cd iOS && xcodegen generate`), but the generated project is committed, so you don't need XcodeGen to build.
