import SwiftUI
import AppKit
import Speech
import AVFoundation
import Translation

// Stores a Color in UserDefaults as a hex string so choices survive relaunch.
extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 24) & 0xFF) / 255,
                  green: Double((v >> 16) & 0xFF) / 255,
                  blue: Double((v >> 8) & 0xFF) / 255,
                  opacity: Double(v & 0xFF) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X%02X",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }
}

struct ContentView: View {
    @State private var now = Date()
    @AppStorage("bgColor") private var bgHex = "1E1E2EFF"
    @AppStorage("textColor") private var textHex = "FFFFFFFF"
    @State private var showOptions = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let deviceName = Host.current().localizedName ?? "this Mac"

    private var bgColor: Binding<Color> {
        Binding(get: { Color(hex: bgHex) }, set: { bgHex = $0.hex })
    }
    private var textColor: Binding<Color> {
        Binding(get: { Color(hex: textHex) }, set: { textHex = $0.hex })
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12:  return "Good morning! ☀️"
        case 12..<17: return "Good afternoon! 🌤️"
        case 17..<21: return "Good evening! 🌇"
        default:      return "Good night! 🌙"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(greeting)
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text(deviceName)
                .font(.title2)
                .opacity(0.75)
            Text(now, format: .dateTime.hour().minute().second())
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
            Text(now, format: .dateTime.weekday(.wide).day().month(.wide).year())
                .font(.headline)
                .opacity(0.75)

            if showOptions {
                VStack(spacing: 10) {
                    ColorPicker("Background colour", selection: bgColor, supportsOpacity: false)
                    ColorPicker("Text colour", selection: textColor, supportsOpacity: false)
                    Button("Reset to default") {
                        bgHex = "1E1E2EFF"; textHex = "FFFFFFFF"
                    }
                }
                .padding(14)
                .frame(width: 280)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.primary)
                .padding(.top, 8)
            }

            Divider()
                .overlay(Color(hex: textHex).opacity(0.3))
                .padding(.vertical, 6)

            VoiceTranslateView(textColor: Color(hex: textHex))
        }
        .foregroundStyle(Color(hex: textHex))
        .padding(40)
        .frame(minWidth: 520, minHeight: 560)
        .background(Color(hex: bgHex))
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation { showOptions.toggle() }
            } label: {
                Image(systemName: showOptions ? "xmark.circle.fill" : "paintpalette.fill")
                    .font(.title2)
                    .foregroundStyle(Color(hex: textHex))
            }
            .buttonStyle(.plain)
            .help("Colour options")
            .padding(12)
        }
        .onReceive(timer) { now = $0 }
    }
}

// MARK: - Voice translation (all on-device Apple frameworks)

enum SpokenLang: String, CaseIterable, Identifiable {
    case english, hindi
    var id: String { rawValue }
    var label: String { self == .english ? "English" : "हिन्दी Hindi" }
    var name: String { self == .english ? "English" : "Hindi" }
    var speechLocales: [String] { self == .english ? ["en-IN", "en-US"] : ["hi-IN"] }
    var language: Locale.Language { Locale.Language(identifier: self == .english ? "en" : "hi") }
    var voiceCodes: [String] { self == .english ? ["en-IN", "en-US"] : ["hi-IN"] }
    var other: SpokenLang { self == .english ? .hindi : .english }
}

@MainActor
final class VoiceTranslator: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var translation = ""
    @Published var status = "Tap the mic and speak"
    @Published var errorMessage: String?
    @Published var permissionDenied = false
    @Published var config: TranslationSession.Configuration?
    @Published var packMissing = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private(set) var source: SpokenLang = .english
    private var pendingText = ""
    private var prepareOnly = false
    private var finished = true
    private var session = 0

    // Auto-stop: after the first speech, stop when there's this much silence.
    static let silenceTimeout: TimeInterval = 2.0
    // Give up (without translating) if no speech at all within this time.
    static let noSpeechTimeout: TimeInterval = 8.0
    // Mic RMS level that counts as "speaking" (resets the silence timer).
    nonisolated static let speechLevelThreshold: Float = 0.02
    private var speechDetected = false
    private var lastSpeechAt = Date()
    private var recordingStartedAt = Date()
    private var monitor: Task<Void, Never>?
    private var onDevice = false

    // MARK: Permissions
    nonisolated static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let speech: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic: Bool = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        return (mic, speech)
    }

    func toggle(_ lang: SpokenLang) {
        if isRecording { stop() } else { Task { await start(lang) } }
    }

    // MARK: Recording
    func start(_ lang: SpokenLang) async {
        errorMessage = nil
        permissionDenied = false
        let perms = await Self.requestPermissions()
        guard perms.mic, perms.speech else {
            permissionDenied = true
            errorMessage = !perms.mic
                ? "Microphone access is off. Allow Good Morning in System Settings › Privacy & Security › Microphone."
                : "Speech Recognition access is off. Allow Good Morning in System Settings › Privacy & Security › Speech Recognition."
            status = "Permission needed"
            return
        }
        guard let rec = lang.speechLocales.lazy
            .compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) })
            .first, rec.isAvailable else {
            errorMessage = "\(lang.name) speech recognition isn't available on this Mac right now."
            return
        }
        synth.stopSpeaking(at: .immediate)
        source = lang
        transcript = ""
        translation = ""
        finished = false
        session += 1
        let mySession = session

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        do {
            task = try Self.startAudio(engine: engine, recognizer: rec, request: req,
                onLevel: { [weak self] in
                    Task { @MainActor in self?.heardSpeech(session: mySession) }
                },
                onResult: { [weak self] text, isFinal, error in
                    Task { @MainActor in
                        self?.handle(text: text, isFinal: isFinal, error: error, session: mySession)
                    }
                })
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        isRecording = true
        onDevice = rec.supportsOnDeviceRecognition
        speechDetected = false
        recordingStartedAt = Date()
        lastSpeechAt = Date()
        status = "Listening\(onDevice ? " (on-device)" : "")… start speaking (stops after 2s of silence)"
        startMonitor(session: mySession)
    }

    // One polling loop per recording drives both timeouts; cancelled on any stop.
    private func startMonitor(session s: Int) {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.isRecording, self.session == s else { return }
                let now = Date()
                if self.speechDetected {
                    if now.timeIntervalSince(self.lastSpeechAt) >= Self.silenceTimeout {
                        self.stop()          // same path as tapping Stop
                        return
                    }
                } else if now.timeIntervalSince(self.recordingStartedAt) >= Self.noSpeechTimeout {
                    self.cancelNoSpeech()
                    return
                }
            }
        }
    }

    private func heardSpeech(session s: Int) {
        guard s == session, isRecording else { return }
        lastSpeechAt = Date()
        if !speechDetected {
            speechDetected = true
            status = "Listening\(onDevice ? " (on-device)" : "")… stops after 2s of silence"
        }
    }

    private func tearDownAudio() {
        monitor?.cancel()
        monitor = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
    }

    private func cancelNoSpeech() {
        guard isRecording else { return }
        tearDownAudio()
        finished = true
        task?.cancel()
        task = nil
        request = nil
        session += 1
        status = "Didn't hear anything. Tap the mic and start speaking."
    }

    // Kept nonisolated so audio/recognition callbacks (background threads) don't inherit MainActor.
    nonisolated static func startAudio(engine: AVAudioEngine,
                                       recognizer: SFSpeechRecognizer,
                                       request: SFSpeechAudioBufferRecognitionRequest,
                                       onLevel: @escaping @Sendable () -> Void,
                                       onResult: @escaping @Sendable (String?, Bool, Error?) -> Void) throws -> SFSpeechRecognitionTask {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "GoodMorning", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input found."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            // RMS of channel 0; report only when loud enough to count as speech.
            if let data = buffer.floatChannelData, buffer.frameLength > 0 {
                let ch = data[0]
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                if (sum / Float(n)).squareRoot() > speechLevelThreshold { onLevel() }
            }
        }
        engine.prepare()
        try engine.start()
        return recognizer.recognitionTask(with: request) { result, error in
            onResult(result?.bestTranscription.formattedString, result?.isFinal ?? false, error)
        }
    }

    func stop() {
        guard isRecording else { return }
        tearDownAudio()
        status = "Translating…"
        let mySession = session
        // Don't wait long for the "final" result: use the latest text after a short grace period.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if self.session == mySession { self.finish() }
        }
    }

    private func handle(text: String?, isFinal: Bool, error: Error?, session s: Int) {
        guard s == session, !finished else { return }
        if let text, !text.isEmpty {
            if text != transcript { heardSpeech(session: s) }
            transcript = text
        }
        if isFinal {
            if isRecording { stop() }
            finish()
        } else if error != nil {
            if isRecording { stop() }
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        task?.cancel()
        task = nil
        request = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "Didn't catch that. Try again."
            return
        }
        translate(text)
    }

    // MARK: Translation
    private func trigger() {
        let wanted = TranslationSession.Configuration(source: source.language, target: source.other.language)
        if config?.source == wanted.source && config?.target == wanted.target {
            config?.invalidate()
        } else {
            config = wanted
        }
    }

    func translate(_ text: String) {
        pendingText = text
        prepareOnly = false
        trigger()
    }

    func downloadPacks(for lang: SpokenLang) {
        source = lang
        prepareOnly = true
        trigger()
    }

    func checkPacks(for lang: SpokenLang) async {
        let status = await LanguageAvailability().status(from: lang.language, to: lang.other.language)
        packMissing = (status == .supported)
    }

    func run(_ session: TranslationSession) async {
        if prepareOnly {
            prepareOnly = false
            do {
                try await session.prepareTranslation()
                status = "Languages ready. Tap the mic and speak"
                packMissing = false
            } catch {
                errorMessage = "Language download didn't finish: \(error.localizedDescription)"
            }
            return
        }
        let text = pendingText
        guard !text.isEmpty else { return }
        do {
            let response = try await session.translate(text)
            translation = response.targetText
            status = "Done"
            packMissing = false
            speak()
        } catch {
            status = "Translation failed"
            errorMessage = "Couldn't translate: \(error.localizedDescription). You may need to download English and Hindi in System Settings › General › Language & Region › Translation Languages."
        }
    }

    // MARK: Speech output
    func speak() {
        guard !translation.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let target = source.other
        let utterance = AVSpeechUtterance(string: translation)
        utterance.voice = target.voiceCodes.lazy.compactMap { AVSpeechSynthesisVoice(language: $0) }.first
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }
}

struct VoiceTranslateView: View {
    @StateObject private var vt = VoiceTranslator()
    @AppStorage("spokenLang") private var spoken: SpokenLang = .english
    let textColor: Color

    var body: some View {
        VStack(spacing: 12) {
            Text("Voice translate").font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                Text("I'm speaking")
                Picker("", selection: $spoken) {
                    ForEach(SpokenLang.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .disabled(vt.isRecording)
                Image(systemName: "arrow.right")
                Text(spoken.other.name).fontWeight(.semibold)
            }

            Button { vt.toggle(spoken) } label: {
                ZStack {
                    Circle()
                        .fill(vt.isRecording ? Color.red : textColor.opacity(0.18))
                        .frame(width: 78, height: 78)
                    Image(systemName: vt.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(vt.isRecording ? Color.white : textColor)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(vt.isRecording ? "Stop and translate" : "Start recording")

            Text(vt.status).font(.callout).opacity(0.75)

            if vt.packMissing {
                Button("Download \(spoken.name) → \(spoken.other.name) for offline translation") {
                    vt.downloadPacks(for: spoken)
                }
                .font(.callout)
            }

            if let err = vt.errorMessage {
                VStack(spacing: 6) {
                    Text(err).font(.callout).multilineTextAlignment(.center)
                    if vt.permissionDenied {
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }

            box(title: "You said (\(vt.isRecording ? spoken.name : vt.source.name))",
                text: vt.transcript, placeholder: "Your words will appear here…")
            box(title: "Translation (\(vt.isRecording ? spoken.other.name : vt.source.other.name))",
                text: vt.translation, placeholder: "The translation will appear and be spoken here…",
                replay: !vt.translation.isEmpty)
        }
        .frame(width: 440)
        .translationTask(vt.config) { session in
            await vt.run(session)
        }
        .task(id: spoken) { await vt.checkPacks(for: spoken) }
    }

    @ViewBuilder
    private func box(title: String, text: String, placeholder: String, replay: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).opacity(0.7)
                Spacer()
                if replay {
                    Button { vt.speak() } label: {
                        Label("Replay", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(textColor)
                }
            }
            Text(text.isEmpty ? placeholder : text)
                .font(.body)
                .opacity(text.isEmpty ? 0.45 : 1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
        }
        .padding(12)
        .background(textColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

@main
struct GoodMorningApp: App {
    var body: some Scene {
        WindowGroup("Greeting") { ContentView() }
            .windowResizability(.contentSize)
    }
}
