# Good Morning App

A tiny SwiftUI macOS app that greets you based on the time of day (morning, afternoon, evening, night), shows your Mac's name and a live clock, and lets you pick background and text colours (saved between launches).

## Voice translate (English ⇄ Hindi)

Pick the language you're speaking (English or Hindi), tap the mic (or press Space), talk, then tap stop. The app shows a live transcript, translates it into the other language and speaks the translation aloud. Use **Replay** to hear it again.

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
