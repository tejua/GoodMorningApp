// Shared with the Mac app (../main.swift): voice translation engine.
// Same logic as macOS v1.2, adapted for iOS (AVAudioSession, iOS permissions/settings text).
import SwiftUI
import Speech
import AVFoundation
import Translation

final class SpeechDoneDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onDone: (() -> Void)?
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onDone?() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onDone?() }
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

    // MARK: iOS audio session
    private let speechDelegate = SpeechDoneDelegate()
    private var interruptionObserver: NSObjectProtocol?

    init() {
        speechDelegate.onDone = { [weak self] in
            Task { @MainActor in self?.deactivateAudioSessionIfIdle() }
        }
        synth.delegate = speechDelegate
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.handleInterruption() }
        }
    }

    private func activateAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        // playAndRecord + defaultToSpeaker so the translation plays loudly after recording.
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
    }

    private func deactivateAudioSessionIfIdle() {
        guard !isRecording, !synth.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // A phone call or Siri took the audio: stop speaking and finish the recording (single-fire stop).
    private func handleInterruption() {
        synth.stopSpeaking(at: .immediate)
        if isRecording { stop() }
    }

    // MARK: Permissions
    nonisolated static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let speech: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
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
                ? "Microphone access is off. Turn it on in Settings › Apps › Good Morning › Microphone."
                : "Speech Recognition access is off. Turn it on in Settings › Apps › Good Morning › Speech Recognition."
            status = "Permission needed"
            return
        }
        guard let rec = lang.speechLocales.lazy
            .compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) })
            .first, rec.isAvailable else {
            errorMessage = "\(lang.name) speech recognition isn't available on this device right now."
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
            try activateAudioSession()
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
        deactivateAudioSessionIfIdle()
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
            deactivateAudioSessionIfIdle()
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
            deactivateAudioSessionIfIdle()
            errorMessage = "Couldn't translate: \(error.localizedDescription). You may need to download English and Hindi in Settings › Apps › Translate › Downloaded Languages."
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
        try? activateAudioSession()   // route playback to the loudspeaker
        synth.speak(utterance)
    }
}
