# Good Morning App

A tiny SwiftUI macOS app that greets you based on the time of day (morning, afternoon, evening, night), shows your Mac's name and a live clock, and lets you pick background and text colours (saved between launches).

## Voice translate (English ⇄ Hindi)

Pick the language you're speaking (English or Hindi), tap the mic (or press Space), and talk. Recording stops by itself after 2 seconds of silence (or tap stop / press Space any time); if nothing is heard for 8 seconds it stops without translating. The app shows a live transcript, translates it into the other language and speaks the translation aloud. Use **Replay** to hear it again.

Everything runs on-device with Apple frameworks, so it's fast and needs no API keys:

- **Speech** + **AVAudioEngine** for live transcription (on-device recognition when available)
- **Translation** for English ⇄ Hindi translation
- **AVSpeechSynthesizer** for spoken playback (Hindi and Indian English voices)

On first use macOS asks for **Microphone** and **Speech Recognition** access. The first translation may ask you to download the English/Hindi language packs (also in System Settings › General › Language & Region › Translation Languages); after that it works offline.

## Build

```bash
./build.sh
```

This compiles `main.swift` with `swiftc` into `~/Desktop/Good Morning.app` and opens it. Requires macOS 15+ and Xcode command line tools.

## iPhone / iPad (iOS) app

The `iOS/` folder has an iOS version with the same features: time-based greeting, device name, live clock and date, background and text colour pickers, and English ⇄ Hindi voice translate with 2-second silence auto-stop.

1. Open `iOS/GoodMorning.xcodeproj` in Xcode.
2. Select the **GoodMorning** target › **Signing & Capabilities** and pick your Team (automatic signing).
3. Plug in your iPhone, select it as the run destination and press **Run**. The first time, you may need to trust the developer in Settings › General › VPN & Device Management.

Requires **iOS 18+** (the Translation framework needs it). On first use iOS asks for **Microphone** and **Speech Recognition** access, and the first translation may ask to download the English/Hindi language packs.

Note: since iOS 16, apps see a generic device name (for example "iPhone") instead of your phone's personal name, unless Apple grants a special entitlement.

The Xcode project is generated from `iOS/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`cd iOS && xcodegen generate`), but the generated project is committed, so you don't need XcodeGen to build.
