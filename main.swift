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
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onDone?() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onDone?() }
}

struct LiveSegment: Identifiable, Equatable {
    let id = UUID()
    let said: String
    var translation: String = ""
    let from: SpokenLang
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

    init() {
        speechDelegate.onDone = { [weak self] in
            Task { @MainActor in self?.liveSpeechDone() }
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

    func toggle(_ lang: SpokenLang, live: Bool = false) {
        if isRecording {
            if liveActive { stopLive() } else { stop() }
        } else {
            Task { if live { await startLive(lang) } else { await start(lang) } }
        }
    }

    // MARK: - Live mode (sentence-by-sentence)
    func startLive(_ lang: SpokenLang) async {
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
            guard sink.append(buffer) else { return }   // muted while speaking
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
        let seg = LiveSegment(said: text, from: source)
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
                    errorMessage = "Couldn't translate: \(error.localizedDescription). You may need to download English and Hindi in System Settings › General › Language & Region › Translation Languages."
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
        speakText(seg.translation, in: seg.from.other)
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
            speakText(seg.translation, in: seg.from.other)
        }
    }

    private func speakText(_ text: String, in lang: SpokenLang) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = lang.voiceCodes.lazy.compactMap { AVSpeechSynthesisVoice(language: $0) }.first
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
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
    @AppStorage("liveMode") private var live = false
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
                .frame(width: 200)
                .disabled(vt.isRecording)
                Image(systemName: "arrow.right")
                Text(spoken.other.name).fontWeight(.semibold)
                Toggle("Live", isOn: $live)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(vt.isRecording)
                    .help("Live: keep listening and translate sentence by sentence")
                    .padding(.leading, 6)
            }

            Button { vt.toggle(spoken, live: live) } label: {
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
            .help(vt.isRecording ? (vt.liveActive ? "Stop live translation" : "Stop and translate")
                                 : (live ? "Start live translation" : "Start recording"))

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
            if live || vt.liveActive {
                box(title: "Live translation (\(vt.isRecording ? spoken.other.name : vt.source.other.name))",
                    text: vt.livePartialTranslation, placeholder: "Translates as you speak…")
            } else {
                box(title: "Translation (\(vt.isRecording ? spoken.other.name : vt.source.other.name))",
                    text: vt.translation, placeholder: "The translation will appear and be spoken here…",
                    replay: !vt.translation.isEmpty)
            }

            if live || vt.liveActive || !vt.history.isEmpty {
                historyList
            }
        }
        .frame(width: 500)
        .translationTask(vt.config) { session in
            await vt.run(session)
        }
        .task(id: spoken) { await vt.checkPacks(for: spoken) }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History").font(.caption.weight(.semibold)).opacity(0.7)
                Spacer()
                Button("Clear") { vt.clearHistory() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(textColor)
                    .disabled(vt.history.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if vt.history.isEmpty {
                            Text("Finished sentences will appear here.")
                                .opacity(0.45)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(vt.history) { seg in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(seg.said).font(.callout).opacity(0.75)
                                    Text(seg.failed ? "⚠️ Couldn't translate" : (seg.translation.isEmpty ? "…" : seg.translation))
                                        .font(.body.weight(.medium))
                                }
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button { vt.replay(seg) } label: {
                                    Image(systemName: "speaker.wave.2.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(textColor)
                                .disabled(seg.translation.isEmpty)
                                .help("Replay")
                            }
                            .id(seg.id)
                            Divider().overlay(textColor.opacity(0.15))
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(height: 200)
                .onChange(of: vt.history) { _, h in
                    if let last = h.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(12)
        .background(textColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
