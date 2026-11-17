import Foundation
import AVFoundation
import Speech

// Hidden self-test for "Correct my English": `open "Good Morning.app" --args --selftest-correct`
// Writes ~/Library/Logs/GoodMorning/correct-selftest.txt and quits.
@MainActor
enum CorrectorSelfTest {
    /// (spoken sentence with a mistake, acceptable corrections separated by "|")
    static let wrong: [(String, String)] = [
        ("I am agree with you.", "I agree with you."),
        ("He don't know the answer.", "He doesn't know the answer."),
        ("She don't like spicy food.", "She doesn't like spicy food."),
        ("We will discuss about this tomorrow.", "We will discuss this tomorrow."),
        ("Please return back the book.", "Please return the book."),
        ("I am working here since 2 years.", "I have been working here for 2 years."),
        ("This phone is more better than that one.", "This phone is better than that one."),
        ("I have went to Delhi last year.", "I went to Delhi last year."),
        ("Did he went to school?", "Did he go to school?"),
        ("Yesterday I go to the market.", "Yesterday I went to the market."),
        ("Tomorrow I went to Mumbai.", "Tomorrow I will go to Mumbai."),
        ("He go to office every day.", "He goes to the office every day.|He goes to office every day."),
        ("My friend have a new car.", "My friend has a new car."),
        ("I didn't saw him.", "I didn't see him."),
        ("She can speaks English well.", "She can speak English well."),
        ("I am having two sisters.", "I have two sisters."),
        ("He is knowing the answer.", "He knows the answer."),
        ("I don't have no money.", "I don't have any money."),
        ("Where you are going?", "Where are you going?"),
        ("What you want?", "What do you want?"),
        ("She is elder than me.", "She is older than me."),
        ("He married with her last year.", "He married her last year."),
        ("I reached to home late.", "I reached home late."),
        ("Let's go to home.", "Let's go home."),
        ("I am doing this job from 2019.", "I have been doing this job since 2019."),
        ("He is senior than me.", "He is senior to me."),
        ("Can you borrow me your pen?", "Can you lend me your pen?"),
        ("She explained me the problem.", "She explained the problem to me."),
        ("I am very much happy.", "I am very happy."),
        ("One of my friend is a doctor.", "One of my friends is a doctor."),
        ("There is many people here.", "There are many people here."),
        ("He has many informations.", "He has a lot of information."),
        ("I am an student.", "I am a student."),
        ("She is a honest girl.", "She is an honest girl."),
        ("I went to the market yesterday and buyed apples.", "I went to the market yesterday and bought apples."),
        ("He is more taller than his brother.", "He is taller than his brother."),
        ("I didn't went there.", "I didn't go there."),
        ("She doesn't likes tea.", "She doesn't like tea."),
        ("Everybody are happy.", "Everybody is happy."),
        ("I has finished my work.", "I have finished my work."),
        ("They was playing cricket.", "They were playing cricket."),
        ("He did not came yesterday.", "He did not come yesterday."),
        ("I will going to Pune.", "I will go to Pune."),
        ("My mother cook food every day.", "My mother cooks food every day."),
        ("Last week we watch a movie.", "Last week we watched a movie."),
        ("I am waiting since morning.", "I have been waiting since morning."),
        ("I can able to do it.", "I can do it.|I am able to do it."),
        ("I didn't knew that.", "I didn't know that."),
        ("Myself Rahul.", "I am Rahul.|My name is Rahul."),
        ("Me and my friend went to the park.", "My friend and I went to the park."),
        ("She sing very well.", "She sings very well."),
        ("How much books do you have?", "How many books do you have?"),
        ("I am not knowing what to do.", "I don't know what to do."),
        ("He told to me the truth.", "He told me the truth."),
        ("I prefer tea than coffee.", "I prefer tea to coffee."),
        ("I am going to market.", "I am going to the market."),
        ("I listen music every day.", "I listen to music every day."),
        ("I am waiting you.", "I am waiting for you."),
        ("Its raining outside.", "It's raining outside."),
        ("He has went home.", "He has gone home."),
    ]
    /// Written separately as a held-out check (not used to tune the rules).
    static let heldOut: [(String, String)] = [
        ("My brother don't eat meat.", "My brother doesn't eat meat."),
        ("Last night she cook dinner for us.", "Last night she cooked dinner for us."),
        ("They has two children.", "They have two children."),
        ("I seen that movie already.", "I have seen that movie already.|I saw that movie already."),
        ("He can drives a car.", "He can drive a car."),
        ("We was late for the meeting.", "We were late for the meeting."),
        ("Did you ate breakfast?", "Did you eat breakfast?"),
        ("She is liking this song.", "She likes this song."),
        ("I am staying in Bangalore since 2015.", "I have been staying in Bangalore since 2015."),
        ("Please discuss about the issue with your manager.", "Please discuss the issue with your manager."),
        ("This is a umbrella.", "This is an umbrella."),
        ("He is more smarter than me.", "He is smarter than me."),
        ("Two days ago I meet my teacher.", "Two days ago I met my teacher."),
        ("Next week I visited my uncle.", "Next week I will visit my uncle."),
        ("Where she is going?", "Where is she going?"),
        ("I don't know nothing about it.", "I don't know anything about it."),
        ("The children is playing outside.", "The children are playing outside."),
        ("My sister work in a bank.", "My sister works in a bank."),
        ("I have ate my lunch.", "I have eaten my lunch."),
        ("Why you are angry?", "Why are you angry?"),
    ]
    /// Exactly what the en-IN recogniser produced in the audio test (commas, "Hi" for "I", …).
    static let recognised: [(String, String)] = [
        ("Yesterday, I go to the market", "Yesterday I went to the market."),
        ("Tomorrow, I went to Mumbai", "Tomorrow I will go to Mumbai."),
        ("Last week, we watch a movie", "Last week we watched a movie."),
        ("Myself, Rahul", "I am Rahul.|My name is Rahul."),
        ("I am waiting, you", "I am waiting for you."),
        ("Last night, she cook dinner for us", "Last night she cooked dinner for us."),
        ("Two days ago, I meet my teacher", "Two days ago I met my teacher."),
        ("Next week, I visited my uncle", "Next week I will visit my uncle."),
        ("I don't know, nothing about it", "I don't know anything about it."),
        ("Hey, how now you are doing?", "Hey how are you doing now?"),
        ("Hi, I am working here since two years", "Hi I have been working here for two years."),
    ]
    static let correct: [String] = [
        "I agree with you.", "She doesn't like spicy food.", "We discussed the plan yesterday.",
        "I have been working here for two years.", "Did he go to school?", "My friend and I went to the park.",
        "There are many people here.", "I am a student.", "He is taller than his brother.",
        "I will go to Mumbai tomorrow.", "Can you lend me your pen?", "She explained the problem to me.",
        "What do you want to eat tonight?", "I am having lunch with my family.", "My mother cooks food every day.",
        "Where are you going?", "It is raining outside.", "Yesterday I went to the market and bought apples.",
        "I like reading books.", "He has gone home.",
        // harder structures (false-alarm check)
        "Since it was raining, I stayed at home.", "Let him go.", "Make it work.", "I saw him go.",
        "The news is good.", "Can you help me find my keys?", "She has two children.", "My parents live in Delhi.",
        "I have known him for ten years.", "He used to play cricket.", "If I were you, I would wait.",
        "We are going to the market.", "They have been friends since childhood.", "Did you see that?",
        "Everyone loves her.", "I am going home.", "There is a lot of traffic today.",
        "The children are playing outside.", "My brother works in Pune.", "I was waiting for you.",
        "I'm happy to help.", "It's a good idea.", "Hey, good morning.", "Since it was raining, I stayed at home.",
        "Yesterday, I went to the market.", "Hey, how are you doing?", "We will meet next week.", "My sister and I live together.",
    ]

    /// How speech recognition tends to format text: capital first letter, punctuation, digits.
    static func speechStyle(_ s: String) -> String { s }
    /// Worst case: no capitals, no punctuation (older recognisers / partial results).
    static func rawStyle(_ s: String) -> String {
        s.lowercased().filter { !".,?!".contains($0) }.replacingOccurrences(of: " i ", with: " i ")
    }

    static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }
            .split(separator: " ").joined(separator: " ")
    }
    static func matches(_ got: String, _ expected: String) -> Bool {
        expected.split(separator: "|").contains { norm(String($0)) == norm(got) }
    }

    struct Score { var caught = 0, fixed = 0, total = 0; var lines: [String] = [] }

    static func score(_ cases: [(String, String)], raw: Bool) async -> Score {
        func style(_ x: String) -> String { raw ? rawStyle(x) : speechStyle(x) }
        var sc = Score()
        for (input, expected) in cases {
            let r = await GrammarCoach.check(style(input))
            sc.total += 1
            let caught = r.verdict == .corrected || r.verdict == .unsure
            let fixed = r.verdict == .corrected && matches(r.corrected, expected)
            if caught { sc.caught += 1 }
            if fixed { sc.fixed += 1 }
            let mark = fixed ? "FIXED " : (caught ? "CAUGHT" : "MISSED")
            sc.lines.append("\(mark) | \(style(input)) → \(r.corrected) [\(r.verdict.rawValue)] tip: \(r.tip)\(r.flags.isEmpty ? "" : " flags: \(r.flags)")")
        }
        return sc
    }

    static func scoreCorrect(raw: Bool) async -> Score {
        func style(_ x: String) -> String { raw ? rawStyle(x) : speechStyle(x) }
        var sc = Score()
        for s in correct {
            let r = await GrammarCoach.check(style(s))
            sc.total += 1
            if r.isCorrect { sc.fixed += 1 }   // fixed = correctly left alone
            if r.verdict == .perfect { sc.caught += 1 }
            sc.lines.append("\(r.isCorrect ? "OK    " : "FALSE+") | \(style(s)) → \(r.corrected) [\(r.verdict.rawValue)] \(r.tip) \(r.flags)")
        }
        return sc
    }

    static func runText() async -> String {
        var out = "Engines: \(GrammarCoach.engineName)\nApple Intelligence: \(GrammarCoach.appleIntelligenceStatus)\n\n"
        let log = GrammarLog.enabled
        GrammarLog.enabled = false
        defer { GrammarLog.enabled = log }
        for raw in [false, true] {
            let name = raw ? "raw lowercase, no punctuation" : "speech-formatted"
            let w = await score(wrong, raw: raw)
            let h = await score(heldOut + recognised, raw: raw)
            let c = await scoreCorrect(raw: raw)
            out += "=== \(name) ===\n"
            out += "Main set:  caught \(w.caught)/\(w.total), fixed exactly \(w.fixed)/\(w.total)\n"
            out += "Held-out + real recogniser output:  caught \(h.caught)/\(h.total), fixed exactly \(h.fixed)/\(h.total)\n"
            out += "Correct:   left alone \(c.fixed)/\(c.total) (Perfect for \(c.caught), the rest Looks correct)\n"
            var lines: [String] = w.lines
            lines.append("--- held-out ---"); lines += h.lines
            lines.append("--- correct ---"); lines += c.lines
            out += lines.joined(separator: "\n")
            out += "\n\n"
        }
        return out
    }

    // MARK: audio path: speak each sentence with TTS → recognise it with SFSpeechRecognizer → check
    static func synthesize(_ text: String, to url: URL) async {
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-US")
        var file: AVAudioFile?
        var done = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            synth.write(u) { buffer in
                guard !done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true; cont.resume(); return
                }
                if file == nil {
                    file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                            commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try? file?.write(from: pcm)
            }
        }
        _ = synth
    }

    static func recognize(_ url: URL, locale: String) async -> String {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)), rec.isAvailable else { return "" }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.addsPunctuation = true
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        var task: SFSpeechRecognitionTask?
        let text: String = await withCheckedContinuation { cont in
            var finished = false
            task = rec.recognitionTask(with: req) { r, e in
                guard !finished else { return }
                if let r, r.isFinal { finished = true; cont.resume(returning: r.bestTranscription.formattedString) }
                else if e != nil { finished = true; cont.resume(returning: r?.bestTranscription.formattedString ?? "") }
            }
        }
        _ = task
        return text
    }

    static func runAudio(locale: String) async -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return "Audio test skipped: Speech Recognition permission isn't granted to this build (not requested).\n"
        }
        let onDevice = SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition ?? false
        var out = "=== audio: TTS → \(locale) speech recognition (\(onDevice ? "on-device" : "server")) → checker ===\n"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gm-selftest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var caught = 0, fixed = 0, total = 0, heardSame = 0, ok = 0
        let log = GrammarLog.enabled
        GrammarLog.enabled = false
        defer { GrammarLog.enabled = log }
        var lines: [String] = []
        for (n, (input, expected)) in (wrong + heldOut).enumerated() {
            let url = dir.appendingPathComponent("s\(n).caf")
            await synthesize(input, to: url)
            let heard = await recognize(url, locale: locale)
            let r = await GrammarCoach.check(heard)
            total += 1
            if norm(heard) == norm(input) { heardSame += 1 }
            let c = r.verdict == .corrected || r.verdict == .unsure
            let f = r.verdict == .corrected && matches(r.corrected, expected)
            if c { caught += 1 }; if f { fixed += 1 }
            lines.append("\(f ? "FIXED " : (c ? "CAUGHT" : "MISSED")) | said: \(input) | heard: \(heard) → \(r.corrected) [\(r.verdict.rawValue)]")
        }
        for (n, s) in correct.enumerated() {
            let url = dir.appendingPathComponent("c\(n).caf")
            await synthesize(s, to: url)
            let heard = await recognize(url, locale: locale)
            let r = await GrammarCoach.check(heard)
            if r.isCorrect { ok += 1 }
            lines.append("\(r.isCorrect ? "OK    " : "FALSE+") | said: \(s) | heard: \(heard) → \(r.corrected) [\(r.verdict.rawValue)]")
        }
        out += "Wrong sentences: caught \(caught)/\(total), fixed exactly \(fixed)/\(total); recogniser kept the words unchanged for \(heardSame)/\(total)\n"
        out += "Correct sentences left alone: \(ok)/\(correct.count)\n"
        return out + lines.joined(separator: "\n") + "\n"
    }

    static func runAndQuit(locale: String) async {
        var report = await runText()
        report += await runAudio(locale: locale)
        let url = GrammarLog.url.deletingLastPathComponent().appendingPathComponent("correct-selftest.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? report.write(to: url, atomically: true, encoding: .utf8)
        exit(0)
    }
}
