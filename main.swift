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
    var preview: VoiceTranslator? = nil   // used only by offscreen preview renders
    @AppStorage("bgColor") private var bgHex = "1E1E2EFF"
    @AppStorage("textColor") private var textHex = "FFFFFFFF"
    @State private var showOptions = false

    private var bgColor: Binding<Color> {
        Binding(get: { Color(hex: bgHex) }, set: { bgHex = $0.hex })
    }
    private var textColor: Binding<Color> {
        Binding(get: { Color(hex: textHex) }, set: { textHex = $0.hex })
    }

    var body: some View {
        TranslatorScreen(textColor: Color(hex: textHex), preview: preview)
            .foregroundStyle(Color(hex: textHex))
            .frame(minWidth: 760, minHeight: 600)
            .background(Color(hex: bgHex).ignoresSafeArea())
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        withAnimation { showOptions.toggle() }
                    } label: {
                        Image(systemName: showOptions ? "xmark.circle.fill" : "paintpalette.fill")
                            .font(.title2)
                            .foregroundStyle(Color(hex: textHex))
                    }
                    .buttonStyle(.plain)
                    .help("Colour options")
                    if showOptions {
                        VStack(spacing: 10) {
                            ColorPicker("Background colour", selection: bgColor, supportsOpacity: false)
                            ColorPicker("Text colour", selection: textColor, supportsOpacity: false)
                            Button("Reset to default") {
                                bgHex = "1E1E2EFF"; textHex = "FFFFFFFF"
                            }
                        }
                        .padding(14)
                        .frame(width: 260)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                    }
                }
                .padding(14)
            }
    }
}

// MARK: - Voice translation (all on-device Apple frameworks)

enum AppMode: String, CaseIterable { case translate, correct }

enum SpokenLang: String, CaseIterable, Identifiable {
    // Raw values of english/hindi kept so saved choices from earlier versions still load.
    case english, hindi, spanish, french, german, japanese, chinese, arabic, portuguese, korean
    var id: String { rawValue }
    var name: String {
        switch self {
        case .english: "English";   case .hindi: "Hindi";     case .spanish: "Spanish"
        case .french: "French";     case .german: "German";   case .japanese: "Japanese"
        case .chinese: "Chinese";   case .arabic: "Arabic";   case .portuguese: "Portuguese"
        case .korean: "Korean"
        }
    }
    var nativeName: String {
        switch self {
        case .english: "English";   case .hindi: "हिन्दी";      case .spanish: "Español"
        case .french: "Français";   case .german: "Deutsch";  case .japanese: "日本語"
        case .chinese: "中文";       case .arabic: "العربية";   case .portuguese: "Português"
        case .korean: "한국어"
        }
    }
    var label: String { nativeName == name ? name : "\(name) · \(nativeName)" }
    /// Speech recognition locales, best first. Also used to pick a synthesis voice.
    var speechLocales: [String] {
        switch self {
        case .english: ["en-IN", "en-US", "en-GB"]; case .hindi: ["hi-IN"]
        case .spanish: ["es-ES", "es-MX", "es-US"]; case .french: ["fr-FR", "fr-CA"]
        case .german: ["de-DE"];                    case .japanese: ["ja-JP"]
        case .chinese: ["zh-CN", "zh-TW"];          case .arabic: ["ar-SA", "ar-AE"]
        case .portuguese: ["pt-BR", "pt-PT"];       case .korean: ["ko-KR"]
        }
    }
    /// Translation framework language.
    var language: Locale.Language {
        let code: String
        switch self {
        case .english: code = "en";    case .hindi: code = "hi";      case .spanish: code = "es"
        case .french: code = "fr";     case .german: code = "de";     case .japanese: code = "ja"
        case .chinese: code = "zh-Hans"; case .arabic: code = "ar";   case .portuguese: code = "pt-BR"
        case .korean: code = "ko"
        }
        return Locale.Language(identifier: code)
    }
    var voiceCodes: [String] { speechLocales }
}

// Thread-safe hand-off from the audio tap to the current Live recognition request.
// While `muted` (translation being spoken), mic buffers are dropped so the speaker isn't re-translated.
final class LiveAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var muted = false
    func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
    func setMuted(_ m: Bool) { lock.lock(); muted = m; lock.unlock() }
    /// Returns false when muted (buffer dropped).
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !muted else { return false }
        request?.append(buffer)
        return true
    }
}

final class SpeechDoneDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onDone: (() -> Void)?
    // Avatar hooks (lip-sync); they don't affect translation/Live logic.
    var onStart: ((AVSpeechUtterance) -> Void)?
    var onWord: ((AVSpeechUtterance, NSRange) -> Void)?
    var onEnd: ((AVSpeechUtterance) -> Void)?
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { onStart?(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) { onWord?(utterance, characterRange) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onDone?(); onEnd?(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onDone?(); onEnd?(utterance) }
}

// Latest mic RMS, written from the audio tap and polled by the avatar (~15×/s) while listening.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Float = 0
    func set(_ x: Float) { lock.lock(); v = x; lock.unlock() }
    var value: Float { lock.lock(); defer { lock.unlock() }; return v }
}
let micMeter = LevelMeter()

struct LiveSegment: Identifiable, Equatable {
    let id = UUID()
    let said: String
    var translation: String = ""
    let from: SpokenLang
    let to: SpokenLang
    var failed = false
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
    private(set) var target: SpokenLang = .hindi

    // Correct-my-English mode
    @Published var correctMode = false
    @Published var correction: CorrectionResult?
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

    // MARK: Live mode state
    @Published var liveActive = false
    @Published var history: [LiveSegment] = []
    @Published var livePartialTranslation = ""
    static let liveHistoryCap = 50
    static let livePause: TimeInterval = 1.0          // pause that ends a segment
    static let liveNoiseFallback: TimeInterval = 2.0  // text unchanged this long ends it even if the room is noisy
    static let liveMaxSegment: TimeInterval = 45      // stay under SFSpeechRecognizer's ~1 min task limit
    static let livePartialDebounce: TimeInterval = 0.3
    private var liveRecognizer: SFSpeechRecognizer?
    private let liveSink = LiveAudioSink()
    private var liveGen = 0            // bumps on every Live start/stop
    private var segId = 0              // bumps on every new segment; stale callbacks are ignored
    private var segStartedAt = Date()
    private var lastTextAt = Date()
    private var lastLevelAt = Date()
    private var partialChangedAt = Date()
    private var lastTranslatedPartial = ""
    private var liveHeardAny = false
    private var liveRunRequested = false
    private var translateQueue: [UUID] = []
    private var speechQueue: [UUID] = []
    private var liveSpeaking = false
    private let speechDelegate = SpeechDoneDelegate()

    // Avatar state (read-only hooks into the synthesizer)
    @Published var avatarSpeaking = false
    @Published var avatarSpeech = ""
    @Published var avatarWordRange: NSRange?
    @Published var avatarWordTick = 0
    private var avatarUtterance: ObjectIdentifier?

    init() {
        speechDelegate.onDone = { [weak self] in
            Task { @MainActor in self?.liveSpeechDone() }
        }
        speechDelegate.onStart = { [weak self] u in
            let id = ObjectIdentifier(u), text = u.speechString
            Task { @MainActor in
                self?.avatarUtterance = id
                self?.avatarSpeech = text
                self?.avatarWordRange = nil
                self?.avatarSpeaking = true
            }
        }
        speechDelegate.onWord = { [weak self] u, range in
            let id = ObjectIdentifier(u)
            Task { @MainActor in
                guard let self, self.avatarUtterance == id else { return }
                self.avatarWordRange = range
                self.avatarWordTick &+= 1
            }
        }
        speechDelegate.onEnd = { [weak self] u in
            let id = ObjectIdentifier(u)
            Task { @MainActor in
                guard let self, self.avatarUtterance == id else { return }
                self.avatarUtterance = nil
                self.avatarSpeaking = false
                self.avatarWordRange = nil
            }
        }
        synth.delegate = speechDelegate
    }

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

    func toggle(_ lang: SpokenLang, to dest: SpokenLang, live: Bool = false) {
        if isRecording {
            if liveActive { stopLive() } else { stop() }
        } else {
            correctMode = false
            Task { if live { await startLive(lang, to: dest) } else { await start(lang, to: dest) } }
        }
    }

    // MARK: - Live mode (sentence-by-sentence)
    func startLive(_ lang: SpokenLang, to dest: SpokenLang) async {
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
        guard !isRecording else { return }
        guard let rec = lang.speechLocales.lazy
            .compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) })
            .first, rec.isAvailable else {
            errorMessage = "\(lang.name) speech recognition isn't available on this Mac right now."
            return
        }
        synth.stopSpeaking(at: .immediate)
        session += 1            // invalidate any non-live timers
        finished = true
        source = lang
        target = dest
        liveRecognizer = rec
        onDevice = rec.supportsOnDeviceRecognition
        transcript = ""
        translation = ""
        livePartialTranslation = ""
        lastTranslatedPartial = ""
        translateQueue.removeAll()
        speechQueue.removeAll()
        liveSpeaking = false
        liveHeardAny = false
        liveSink.setMuted(false)
        liveGen += 1
        let gen = liveGen

        do {
            try Self.startLiveAudio(engine: engine, sink: liveSink, onLevel: { [weak self] in
                Task { @MainActor in self?.liveLevel(gen: gen) }
            })
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        liveActive = true
        isRecording = true
        recordingStartedAt = Date()
        beginSegment()
        status = "Live: listening…"
        liveRunRequested = true
        prepareOnly = false
        trigger()               // starts the long-lived Live translation loop
        startLiveMonitor(gen: gen)
    }

    nonisolated static func startLiveAudio(engine: AVAudioEngine, sink: LiveAudioSink,
                                           onLevel: @escaping @Sendable () -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "GoodMorning", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input found."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard sink.append(buffer) else { micMeter.set(0); return }   // muted while speaking
            if let data = buffer.floatChannelData, buffer.frameLength > 0 {
                let ch = data[0]
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = (sum / Float(n)).squareRoot()
                micMeter.set(rms)        // avatar level display only
                if rms > speechLevelThreshold { onLevel() }
            }
        }
        engine.prepare()
        try engine.start()
    }

    // New recognition request/task for the next segment; the audio engine keeps running.
    private func beginSegment() {
        guard liveActive, let rec = liveRecognizer else { return }
        task?.cancel()
        segId += 1
        let mySeg = segId
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        liveSink.setRequest(req)
        transcript = ""
        livePartialTranslation = ""
        lastTranslatedPartial = ""
        let now = Date()
        segStartedAt = now; lastTextAt = now; lastLevelAt = now; partialChangedAt = now
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in self?.handleLive(text: text, isFinal: isFinal, error: error, seg: mySeg) }
        }
    }

    private func liveLevel(gen: Int) {
        guard gen == liveGen, liveActive else { return }
        lastLevelAt = Date()
    }

    private func handleLive(text: String?, isFinal: Bool, error: Error?, seg: Int) {
        guard seg == segId, liveActive else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            liveHeardAny = true
            lastTextAt = Date()
            partialChangedAt = lastTextAt
        }
        if isFinal {
            finalizeSegment()
        } else if error != nil {
            if transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                // e.g. "no speech" timeout from the recognizer: quietly start a fresh segment.
                let g = liveGen
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if self.liveGen == g && self.segId == seg { self.beginSegment() }
                }
            } else {
                finalizeSegment()
            }
        }
    }

    private func startLiveMonitor(gen: Int) {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.liveActive, self.liveGen == gen else { return }
                let now = Date()
                let hasText = !self.transcript.trimmingCharacters(in: .whitespaces).isEmpty
                if !self.liveHeardAny && self.history.isEmpty && !hasText {
                    if now.timeIntervalSince(self.recordingStartedAt) >= Self.noSpeechTimeout {
                        self.stopLive(hint: "Didn't hear anything. Tap the mic and start speaking.")
                        return
                    }
                    continue
                }
                guard hasText else {
                    // Keep the recognition task fresh during long silences (~1 min task limit).
                    if now.timeIntervalSince(self.segStartedAt) >= Self.liveMaxSegment { self.beginSegment() }
                    continue
                }
                let quiet = now.timeIntervalSince(self.lastTextAt) >= Self.livePause
                    && now.timeIntervalSince(self.lastLevelAt) >= Self.livePause
                if quiet
                    || now.timeIntervalSince(self.lastTextAt) >= Self.liveNoiseFallback
                    || now.timeIntervalSince(self.segStartedAt) >= Self.liveMaxSegment {
                    self.finalizeSegment()
                }
            }
        }
    }

    private func finalizeSegment() {
        guard liveActive else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        request?.endAudio()
        if !text.isEmpty { addSegment(text) }
        beginSegment()
    }

    private func addSegment(_ text: String) {
        let seg = LiveSegment(said: text, from: source, to: target)
        history.append(seg)
        if history.count > Self.liveHistoryCap { history.removeFirst(history.count - Self.liveHistoryCap) }
        translateQueue.append(seg.id)
    }

    func stopLive(hint: String? = nil) {
        guard liveActive else { return }
        let leftover = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        liveActive = false
        isRecording = false
        liveGen += 1
        segId += 1
        monitor?.cancel(); monitor = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        liveSink.setRequest(nil)
        liveSink.setMuted(false)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        liveRecognizer = nil
        speechQueue.removeAll()
        liveSpeaking = false
        synth.stopSpeaking(at: .immediate)
        // Keep what was said last: translate it into history (not spoken).
        if !leftover.isEmpty { addSegment(leftover) }
        transcript = ""
        livePartialTranslation = ""
        status = hint ?? "Live stopped"
    }

    func clearHistory() {
        history.removeAll()
        speechQueue.removeAll()
        translateQueue.removeAll()
    }

    // Long-lived loop inside .translationTask: one request in flight at a time,
    // finished segments first (in order), otherwise only the latest partial (debounced).
    private func runLive(_ session: TranslationSession) async {
        let gen = liveGen
        while !Task.isCancelled && (liveGen == gen || !translateQueue.isEmpty) && (liveActive || !translateQueue.isEmpty) {
            if !translateQueue.isEmpty {
                let id = translateQueue.removeFirst()
                guard let text = history.first(where: { $0.id == id })?.said else { continue }
                do {
                    let r = try await session.translate(text)
                    if let i = history.firstIndex(where: { $0.id == id }) {
                        history[i].translation = r.targetText
                        packMissing = false
                        if liveActive { speechQueue.append(id); speakNextLive() }
                    }
                } catch {
                    if Task.isCancelled { return }
                    if let i = history.firstIndex(where: { $0.id == id }) { history[i].failed = true }
                    errorMessage = "Couldn't translate: \(error.localizedDescription). You may need to download \(source.name) and \(target.name) in System Settings › General › Language & Region › Translation Languages."
                }
                continue
            }
            let partial = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if liveActive, !partial.isEmpty, partial != lastTranslatedPartial,
               Date().timeIntervalSince(partialChangedAt) >= Self.livePartialDebounce {
                let seg = segId
                lastTranslatedPartial = partial
                if let r = try? await session.translate(partial), seg == segId, liveActive {
                    livePartialTranslation = r.targetText   // stale results (old segment) are dropped
                }
                continue
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func speakNextLive() {
        guard liveActive, !liveSpeaking, !speechQueue.isEmpty else { return }
        let id = speechQueue.removeFirst()
        guard let seg = history.first(where: { $0.id == id }), !seg.translation.isEmpty else {
            speakNextLive(); return
        }
        liveSpeaking = true
        liveSink.setMuted(true)          // don't let the speaker echo into the mic
        status = "Live: speaking translation…"
        speakText(seg.translation, in: seg.to)
    }

    private func liveSpeechDone() {
        guard liveActive, liveSpeaking else { return }
        liveSpeaking = false
        if !speechQueue.isEmpty { speakNextLive(); return }
        let g = liveGen
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))   // let the speaker tail die out
            guard self.liveActive, self.liveGen == g, !self.liveSpeaking else { return }
            self.liveSink.setMuted(false)
            self.lastLevelAt = Date(); self.lastTextAt = Date()
            self.status = "Live: listening…"
        }
    }

    func replay(_ seg: LiveSegment) {
        guard !seg.translation.isEmpty else { return }
        if liveActive {
            speechQueue.append(seg.id); speakNextLive()
        } else {
            synth.stopSpeaking(at: .immediate)
            speakText(seg.translation, in: seg.to)
        }
    }

    private func speakText(_ text: String, in lang: SpokenLang) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = lang.voiceCodes.lazy.compactMap { AVSpeechSynthesisVoice(language: $0) }.first
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    // MARK: Recording
    func start(_ lang: SpokenLang, to dest: SpokenLang) async {
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
        target = dest
        transcript = ""
        correction = nil
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
                let rms = (sum / Float(n)).squareRoot()
                micMeter.set(rms)        // avatar level display only
                if rms > speechLevelThreshold { onLevel() }
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
        if correctMode {
            Task { await correct(text) }
        } else {
            translate(text)
        }
    }

    // MARK: Correct my English
    func toggleCorrect() {
        if isRecording {
            if liveActive { stopLive() } else { stop() }
        } else {
            correctMode = true
            Task { await start(.english, to: .english) }   // same recognition + 2 s auto-stop as Translate
        }
    }

    private func correct(_ text: String) async {
        status = "Checking…"
        let result = await GrammarCoach.check(text)
        guard correctMode, !isRecording else { return }
        correction = result
        switch result.verdict {
        case .corrected: status = "Corrected"
        case .perfect: status = "Perfect!"
        case .looksCorrect: status = "Looks correct"
        case .unsure: status = "Not sure"
        }
        speakCorrection()
    }

    func speakCorrection() {
        guard let c = correction else { return }
        synth.stopSpeaking(at: .immediate)
        let line: String
        switch c.verdict {
        case .corrected: line = c.corrected
        case .perfect: line = "Perfect! That's correct."
        case .looksCorrect: line = "Looks correct to me!"
        case .unsure: line = "Hmm, I'm not sure about that one. " + (c.flags.first ?? "")
        }
        speakText(line, in: .english)
    }

    // MARK: Translation
    private func trigger() {
        let wanted = TranslationSession.Configuration(source: source.language, target: target.language)
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

    func downloadPacks(from lang: SpokenLang, to dest: SpokenLang) {
        source = lang
        target = dest
        prepareOnly = true
        trigger()
    }

    func checkPacks(from lang: SpokenLang, to dest: SpokenLang) async {
        let status = await LanguageAvailability().status(from: lang.language, to: dest.language)
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
        if liveRunRequested {
            liveRunRequested = false
            await runLive(session)
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
            errorMessage = "Couldn't translate: \(error.localizedDescription). You may need to download \(source.name) and \(target.name) in System Settings › General › Language & Region › Translation Languages."
        }
    }

    // MARK: Speech output
    func speak() {
        guard !translation.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: translation)
        utterance.voice = target.voiceCodes.lazy.compactMap { AVSpeechSynthesisVoice(language: $0) }.first
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }
}

// MARK: - Full-window translator screen

struct TranslatorScreen: View {
    @StateObject private var vt: VoiceTranslator
    @AppStorage("sourceLang") private var source: SpokenLang = .english
    @AppStorage("targetLang") private var target: SpokenLang = .hindi
    @AppStorage("liveMode") private var live = false
    @AppStorage("showAvatar") private var showAvatar = true
    @AppStorage("appMode") private var mode: AppMode = .translate
    @State private var showHistory = false
    let textColor: Color

    init(textColor: Color, preview: VoiceTranslator? = nil) {
        self.textColor = textColor
        _vt = StateObject(wrappedValue: preview ?? VoiceTranslator())
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geo in stage(geo.size) }
            bottomBar
        }
        .translationTask(vt.config) { session in
            await vt.run(session)
        }
        .task(id: "\(source.rawValue)>\(target.rawValue)") { await vt.checkPacks(from: source, to: target) }
        .onChange(of: source) { old, new in if new == target { target = old } }
        .onChange(of: target) { old, new in if new == source { source = old } }
    }

    // MARK: Top
    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Translator").font(.title2.weight(.bold))
                Spacer()
                Toggle("Avatar", isOn: $showAvatar)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Show the animated avatar")
                    .padding(.trailing, 44)   // room for the palette button
            }
            if let err = vt.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err).font(.callout)
                    if vt.permissionDenied {
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: 640)
                .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
            if vt.packMissing {
                Button("Download \(source.name) → \(target.name) for offline translation") {
                    vt.downloadPacks(from: source, to: target)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: Stage (girl + bubbles)
    private func stage(_ size: CGSize) -> some View {
        let figH = max(260, min(size.height - 8, size.width * 0.9))
        let figW = figH / 2
        let bubbleW = max(190, min(340, (size.width - figW - 70) / 2))
        return Group {
            if showAvatar {
                HStack(alignment: .top, spacing: 18) {
                    VStack { youBubble; Spacer(minLength: 0) }
                        .frame(width: bubbleW)
                        .padding(.top, figH * 0.14)
                    AvatarDriver(vt: vt)
                        .frame(width: figW, height: figH)
                    VStack { herBubble; Spacer(minLength: 0) }
                        .frame(width: bubbleW)
                        .padding(.top, figH * 0.05)
                }
            } else {
                VStack(spacing: 18) {
                    youBubble
                    herBubble
                }
                .frame(width: min(520, size.width - 60))
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.2), value: showAvatar)
    }

    private var youCaption: String {
        mode == .correct ? "You · English" : "You · \(vt.isRecording || vt.transcript.isEmpty ? source.name : vt.source.name)"
    }
    private var herCaption: String { "Translation · \(vt.isRecording ? target.name : vt.target.name)" }

    @ViewBuilder private var youBubble: some View {
        if mode == .correct, !vt.isRecording, let c = vt.correction {
            TalkBubble(caption: "You said", text: c.original, tailOnLeading: false,
                       marks: c.verdict == .corrected ? c.wrong : (c.verdict == .unsure ? c.flagged : []),
                       strike: c.verdict == .corrected, warn: c.verdict == .unsure)
        } else if !vt.transcript.isEmpty {
            TalkBubble(caption: youCaption, text: vt.transcript, tailOnLeading: false)
        } else if vt.isRecording {
            TalkBubble(caption: youCaption, text: "Listening…", tailOnLeading: false, dim: true) {
                LiveLevel()
            }
        }
    }

    private var replayCorrection: some View {
        Button { vt.speakCorrection() } label: { Label("Replay", systemImage: "speaker.wave.2.fill") }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(red: 0.47, green: 0.40, blue: 0.86))
    }

    private func tipLines(_ c: CorrectionResult) -> String? {
        c.tips.isEmpty ? nil : c.tips.prefix(3).map { "💡 " + $0 }.joined(separator: "\n")
    }

    private func verdictCaption(_ c: CorrectionResult?) -> String {
        switch c?.verdict {
        case .perfect: return "Perfect! ✨"
        case .looksCorrect: return "Looks correct 👍"
        case .unsure: return "Hmm, not sure 🤔"
        default: return "Correct English"
        }
    }

    @ViewBuilder private var correctBubble: some View {
        let c = vt.correction
        if vt.avatarSpeaking {
            TalkBubble(caption: verdictCaption(c), text: vt.avatarSpeech,
                       highlight: vt.avatarWordRange, tailOnLeading: true,
                       marks: (c.map { $0.verdict == .corrected && vt.avatarSpeech == $0.corrected } ?? false) ? c!.changed : [],
                       footnote: c.flatMap { tipLines($0) })
        } else if vt.status == "Checking…" {
            EmptyView()
        } else if let c {
            switch c.verdict {
            case .perfect:
                TalkBubble(caption: verdictCaption(c), text: "That's correct — well done! 🎉", tailOnLeading: true,
                           footnote: "Checked by \(c.engine)") { replayCorrection }
            case .looksCorrect:
                TalkBubble(caption: verdictCaption(c), text: "Looks correct to me — I couldn't find a mistake.",
                           tailOnLeading: true,
                           footnote: "I check common grammar mistakes, so I can miss some in longer sentences.") { replayCorrection }
            case .unsure:
                TalkBubble(caption: verdictCaption(c), text: c.flags.first ?? "Something here may be wrong.",
                           tailOnLeading: true,
                           footnote: "I couldn't find a sure fix — try saying it another way.") { replayCorrection }
            case .corrected:
                TalkBubble(caption: verdictCaption(c), text: c.corrected, tailOnLeading: true,
                           marks: c.changed, footnote: tipLines(c)) { replayCorrection }
            }
        } else if vt.errorMessage != nil {
            TalkBubble(caption: "Hmm…", text: vt.permissionDenied ? "I can't hear you yet…" : "Something went wrong.",
                       tailOnLeading: true)
        } else if !vt.isRecording {
            TalkBubble(caption: "Hi!", text: "Say a sentence in English and I'll help you correct it ✍️",
                       tailOnLeading: true, footnote: "Using \(GrammarCoach.engineName)")
        }
    }

    @ViewBuilder private var herBubble: some View {
        if mode == .correct {
            correctBubble
        } else if vt.avatarSpeaking {
            TalkBubble(caption: herCaption, text: vt.avatarSpeech, highlight: vt.avatarWordRange, tailOnLeading: true)
        } else if vt.liveActive {
            let lastDone = vt.history.last(where: { !$0.translation.isEmpty })?.translation ?? ""
            let text = vt.livePartialTranslation.isEmpty ? lastDone : vt.livePartialTranslation
            if !text.isEmpty {
                TalkBubble(caption: herCaption, text: text, tailOnLeading: true, dim: vt.livePartialTranslation.isEmpty)
            }
        } else if vt.status == "Translating…" {
            EmptyView()
        } else if !vt.translation.isEmpty {
            TalkBubble(caption: herCaption, text: vt.translation, tailOnLeading: true) {
                Button { vt.speak() } label: { Label("Replay", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.47, green: 0.40, blue: 0.86))
            }
        } else if let last = vt.history.last(where: { !$0.translation.isEmpty }) {
            TalkBubble(caption: "Translation · \(last.to.name)", text: last.translation, tailOnLeading: true) {
                Button { vt.replay(last) } label: { Label("Replay", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.47, green: 0.40, blue: 0.86))
            }
        } else if vt.errorMessage != nil {
            TalkBubble(caption: "Hmm…", text: vt.permissionDenied ? "I can't hear you yet…" : "Something went wrong.",
                       tailOnLeading: true)
        } else if !vt.isRecording {
            TalkBubble(caption: "Hi!", text: "Pick your languages below and tap the mic 👋", tailOnLeading: true)
        }
    }

    // MARK: Bottom (languages, mic, Live)
    private var bottomBar: some View {
        VStack(spacing: 10) {
            Text(vt.status).font(.callout).opacity(0.75).lineLimit(1)

            Picker("", selection: $mode) {
                Text("Translate").tag(AppMode.translate)
                Text("Correct my English").tag(AppMode.correct)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
            .disabled(vt.isRecording)

            if mode == .correct {
                Text("Speak in English — I'll correct your grammar")
                    .font(.callout)
                    .opacity(0.8)
                    .frame(height: 26)
            } else {
            HStack(spacing: 10) {
                Text("From").font(.callout).opacity(0.7)
                langPicker($source)
                Button {
                    let s = source; source = target; target = s
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 26)
                }
                .buttonStyle(.bordered)
                .help("Swap languages")
                Text("To").font(.callout).opacity(0.7)
                langPicker($target)
            }
            .disabled(vt.isRecording)
            }

            micButton
                .frame(maxWidth: .infinity)
                .overlay(alignment: .center) {
                    HStack(spacing: 14) {
                        Toggle("Live", isOn: $live)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(vt.isRecording || mode == .correct)
                            .help("Live: keep listening and translate sentence by sentence")
                        Button { showHistory.toggle() } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(textColor)
                        .disabled(vt.history.isEmpty)
                        .popover(isPresented: $showHistory, arrowEdge: .top) { historyList }
                    }
                    .fixedSize()
                    .offset(x: 150)
                }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private func langPicker(_ selection: Binding<SpokenLang>) -> some View {
        Picker("", selection: selection) {
            ForEach(SpokenLang.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 170)
    }

    private var micButton: some View {
        Button {
            if mode == .correct { vt.toggleCorrect() } else { vt.toggle(source, to: target, live: live) }
        } label: {
            ZStack {
                Circle()
                    .fill(vt.isRecording ? Color.red : textColor.opacity(0.18))
                    .frame(width: 84, height: 84)
                    .shadow(color: (vt.isRecording ? Color.red : .black).opacity(0.3), radius: 8, y: 3)
                Image(systemName: vt.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(vt.isRecording ? Color.white : textColor)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(vt.isRecording ? (vt.liveActive ? "Stop live translation" : "Stop and translate")
                             : (live ? "Start live translation" : "Start recording"))
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Clear") { vt.clearHistory(); showHistory = false }
                    .disabled(vt.history.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(vt.history) { seg in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(seg.said).font(.callout).foregroundStyle(.secondary)
                                    Text(seg.failed ? "⚠️ Couldn't translate" : (seg.translation.isEmpty ? "…" : seg.translation))
                                        .font(.body.weight(.medium))
                                }
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button { vt.replay(seg) } label: { Image(systemName: "speaker.wave.2.fill") }
                                    .buttonStyle(.borderless)
                                    .disabled(seg.translation.isEmpty)
                                    .help("Replay")
                            }
                            .id(seg.id)
                            Divider()
                        }
                    }
                }
                .onAppear { if let last = vt.history.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                .onChange(of: vt.history) { _, h in
                    if let last = h.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
        .padding(14)
        .frame(width: 380, height: 380)
    }
}

/// Mic level meter that polls the shared meter only while it's on screen.
struct LiveLevel: View {
    @State private var level: CGFloat = 0
    var body: some View {
        LevelBars(level: level, color: Color(red: 0.47, green: 0.40, blue: 0.86))
            .task {
                while !Task.isCancelled {
                    level = level * 0.55 + min(1, CGFloat(micMeter.value) * 14) * 0.45
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
    }
}

// MARK: - Avatar driver: maps VoiceTranslator state to the figure's pose

struct AvatarDriver: View {
    @ObservedObject var vt: VoiceTranslator

    @State private var mouth: CGFloat = 0
    @State private var blink: CGFloat = 0
    @State private var nod: CGFloat = 0
    @State private var level: CGFloat = 0
    @State private var thinkPhase = 0
    @State private var gestureL = CGPoint(x: 42, y: 224)
    @State private var gestureR = CGPoint(x: 158, y: 224)
    @State private var lastWordAt = Date.distantPast
    @State private var lastNodAt = Date.distantPast
    @State private var paused = false

    private var mood: AvatarMood {
        if vt.avatarSpeaking { return .speaking }
        if vt.isRecording { return .listening }
        if vt.status == "Translating…" || vt.status == "Checking…" { return .thinking }
        if vt.errorMessage != nil { return .concerned }
        return .idle
    }

    private struct Pose { var tilt, look, brow, smile: CGFloat; var l, r: CGPoint }

    private func pose(_ m: AvatarMood) -> Pose {
        let restL = CGPoint(x: 63, y: 249), restR = CGPoint(x: 137, y: 249)   // relaxed, arms by her sides
        switch m {
        case .idle:      return Pose(tilt: 0, look: 0, brow: 0, smile: 0.9, l: restL, r: restR)
        case .listening: return Pose(tilt: 6, look: 0, brow: 0.7, smile: 0.5, l: restL, r: CGPoint(x: 154, y: 108))  // hand cupped at ear
        case .thinking:  return Pose(tilt: -3, look: 1, brow: 0.35, smile: 0.3, l: restL, r: CGPoint(x: 110, y: 141)) // hand under chin
        case .speaking:  return Pose(tilt: 0, look: 0, brow: 0.3,
                                     smile: (vt.correctMode && vt.correction?.verdict == .perfect) ? 1 : 0.7,  // big smile for "Perfect!"
                                     l: gestureL, r: gestureR)
        case .concerned: return Pose(tilt: -2, look: 0, brow: -1, smile: -0.5,
                                     l: CGPoint(x: 94, y: 226), r: CGPoint(x: 106, y: 226))            // hands clasped
        }
    }

    var body: some View {
        let m = mood
        let p = pose(m)
        // Slow breathing/sway at 12 fps keeps CPU low; paused when the window is hidden.
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let bob = paused ? 0 : CGFloat(sin(t * 2 * .pi / 4.8)) * 2
            let sway = paused ? 0 : sin(t * 2 * .pi / 6.5) * (m == .idle ? 1.4 : 0.6)
            AvatarFigure(mouth: mouth, tilt: p.tilt, lookUp: p.look, blink: blink, brow: p.brow, smile: p.smile,
                         waves: m == .listening ? max(0.15, level) : 0, handL: p.l, handR: p.r)
                .equatable()            // skip redrawing the Canvas when only bob/sway change
                .drawingGroup()         // rasterise once; bob/sway just move the cached layer
                .offset(y: bob + nod)
                .rotationEffect(.degrees(sway), anchor: .bottom)
        }
        .overlay(alignment: .topTrailing) {
            if m == .thinking { ThoughtBubble(phase: thinkPhase).offset(x: 8, y: 6) }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: m)
        .task(id: paused) { await blinkLoop() }
        .task(id: "\(m)-\(paused)") { await moodLoop(m) }
        .onChange(of: vt.transcript) { _, t in nodIfNeeded(t) }
        .onChange(of: vt.avatarWordTick) { _, _ in wordPulse() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let w = note.object as? NSWindow, !(w is NSPanel) else { return }
            let hidden = !w.occlusionState.contains(.visible)
            if hidden != paused { paused = hidden }
        }
    }

    private func blinkLoop() async {
        while !Task.isCancelled && !paused {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 2000...5000)))
            if Task.isCancelled { return }
            let times = Int.random(in: 0..<6) == 0 ? 2 : 1   // occasional double blink
            for _ in 0..<times {
                withAnimation(.easeIn(duration: 0.06)) { blink = 1 }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeOut(duration: 0.09)) { blink = 0 }
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    private func moodLoop(_ m: AvatarMood) async {
        if m != .speaking { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { mouth = 0 } }
        if m != .listening { level = 0 }
        guard !paused else { return }
        switch m {
        case .listening:
            while !Task.isCancelled {
                let target = min(1, CGFloat(micMeter.value) * 14)
                level = level * 0.55 + target * 0.45
                try? await Task.sleep(for: .milliseconds(66))
            }
        case .speaking:
            // Fallback syllable motion between word callbacks, plus hand gestures.
            var open = true
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                tick += 1
                if Date().timeIntervalSince(lastWordAt) > 0.22 {
                    open.toggle()
                    withAnimation(.spring(response: 0.13, dampingFraction: 0.65)) {
                        mouth = open ? .random(in: 0.4...0.85) : .random(in: 0.05...0.2)
                    }
                }
                if tick % 5 == 0 {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                        gestureL = CGPoint(x: .random(in: 34...50), y: .random(in: 212...238))
                        gestureR = CGPoint(x: .random(in: 150...166), y: .random(in: 212...238))
                    }
                }
            }
        case .thinking:
            while !Task.isCancelled {
                thinkPhase += 1
                try? await Task.sleep(for: .milliseconds(350))
            }
        case .idle, .concerned:
            break
        }
    }

    private func wordPulse() {
        guard vt.avatarSpeaking else { return }
        lastWordAt = Date()
        withAnimation(.spring(response: 0.11, dampingFraction: 0.55)) { mouth = .random(in: 0.6...1.0) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            guard vt.avatarSpeaking else { return }
            withAnimation(.spring(response: 0.14, dampingFraction: 0.7)) { mouth = .random(in: 0.12...0.3) }
        }
    }

    private func nodIfNeeded(_ text: String) {
        guard mood == .listening, !text.isEmpty, Date().timeIntervalSince(lastNodAt) > 0.8 else { return }
        lastNodAt = Date()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { nod = 3.5 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { nod = 0 }
        }
    }
}

@main
struct GoodMorningApp: App {
    init() {
        // Hidden diagnostics: `open "Good Morning.app" --args --selftest-correct`
        if CommandLine.arguments.contains("--selftest-correct") {
            Task { @MainActor in await CorrectorSelfTest.runAndQuit(locale: SpokenLang.english.speechLocales[0]) }
        }
    }

    var body: some Scene {
        WindowGroup("Translator") { ContentView() }
            .defaultSize(width: 980, height: 780)
            .windowResizability(.contentMinSize)   // freely resizable, supports macOS full screen
    }
}
