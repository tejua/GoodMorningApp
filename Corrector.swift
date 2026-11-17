import Foundation
import AppKit
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - "Correct my English" (on-device only)
//
// GrammarCoach runs a pipeline of pluggable GrammarEngines, each fed the previous one's output:
//   Apple Intelligence (when enabled) → built-in rules → macOS grammar checker.
// A future engine (e.g. a bundled Core ML model) only has to conform to GrammarEngine and be added to
// `GrammarCoach.engines`.

enum Verdict: String {
    case corrected      // we changed something and can explain why
    case perfect        // every engine checked it and found nothing
    case looksCorrect   // nothing found, but the sentence is long/unusual, so we don't over-claim
    case unsure         // something looks off but no engine could fix it
}

struct CorrectionResult: Equatable {
    let original: String
    let corrected: String
    let tips: [String]        // why each fix was made
    let flags: [String]       // possible problems we could not fix
    let wrong: [NSRange]      // ranges in `original` that were changed (struck through)
    let changed: [NSRange]    // ranges in `corrected` that are new/fixed (highlighted)
    let flagged: [NSRange]    // ranges in `original` that look doubtful (unsure)
    let verdict: Verdict
    let engine: String
    var tip: String { tips.first ?? "" }
    var isCorrect: Bool { verdict == .perfect || verdict == .looksCorrect }
}

struct GrammarFlag { let word: String; let note: String }

struct EngineOutput {
    var text: String
    var tips: [String] = []
    var flags: [GrammarFlag] = []
}

/// Anything that can check one spoken English sentence on-device.
@MainActor
protocol GrammarEngine {
    var name: String { get }
    var isAvailable: Bool { get }
    /// A clean pass from an authoritative engine (an ML model) is enough to say "Perfect!" on its own.
    var isAuthoritative: Bool { get }
    /// Return nil when the engine failed: a failure is never treated as "correct".
    func check(_ text: String) async -> EngineOutput?
}

// MARK: - Coach

@MainActor
enum GrammarCoach {
    static var engines: [any GrammarEngine] = defaultEngines()

    static func defaultEngines() -> [any GrammarEngine] {
        var e: [any GrammarEngine] = []
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { e.append(AppleIntelligenceEngine()) }
        #endif
        e.append(RulesEngine())
        e.append(SystemGrammarEngine())
        return e
    }

    static var activeEngines: [any GrammarEngine] { engines.filter { $0.isAvailable } }
    static var engineName: String { activeEngines.map(\.name).joined(separator: " + ") }

    static var appleIntelligenceStatus: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleIntelligenceEngine.statusText }
        #endif
        return "needs macOS 26"
    }

    static func check(_ raw: String) async -> CorrectionResult {
        let original = raw.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        GrammarLog.write("heard: \"\(original)\"")
        var text = original, tips: [String] = [], flags: [GrammarFlag] = []
        var used: [String] = [], failed = false, authoritativeClean = false
        for engine in activeEngines where !original.isEmpty {
            guard let out = await engine.check(text) else {
                failed = true
                GrammarLog.write("  \(engine.name): FAILED")
                continue
            }
            used.append(engine.name)
            let changedHere = !sameWords(out.text, text)
            if engine.isAuthoritative && !changedHere && out.flags.isEmpty { authoritativeClean = true }
            GrammarLog.write("  \(engine.name): \"\(out.text)\" tips=\(out.tips) flags=\(out.flags.map(\.note))")
            if changedHere {
                text = out.text
                for t in out.tips where !tips.contains(t) { tips.append(t) }
            }
            for f in out.flags where !flags.contains(where: { $0.word.lowercased() == f.word.lowercased() }) { flags.append(f) }
        }
        let (wrong, changed) = diff(original, text)
        let verdict: Verdict
        if original.isEmpty { verdict = .unsure }
        else if !wrong.isEmpty || !changed.isEmpty { verdict = .corrected }
        else if !flags.isEmpty { verdict = .unsure }
        else if !hasVerb(original) && !isGreeting(original) {
            flags.append(GrammarFlag(word: "", note: "I couldn't find a verb — was that a full sentence? Try saying it again."))
            verdict = .unsure
        }
        else if !failed && (authoritativeClean || looksSimpleAndKnown(original)) { verdict = .perfect }
        else { verdict = .looksCorrect }

        var finalTips = verdict == .corrected ? tips : []
        if verdict == .corrected {
            if finalTips.isEmpty { finalTips = ["This is the standard English way to say it."] }
            finalTips += flags.map { "Also check: \($0.note)" }
        }
        let flagged = verdict == .unsure ? flags.filter { !$0.word.isEmpty }.compactMap { range(of: $0.word, in: original) } : []
        let r = CorrectionResult(original: original, corrected: verdict == .corrected ? text : original,
                                 tips: finalTips, flags: flags.map(\.note), wrong: wrong, changed: changed,
                                 flagged: flagged, verdict: verdict, engine: used.joined(separator: " + "))
        GrammarLog.write("  → \(verdict.rawValue): \"\(r.corrected)\" tips=\(r.tips) flags=\(r.flags)")
        return r
    }

    /// "Perfect!" only for short, ordinary sentences where every word is known and there is a verb.
    static func looksSimpleAndKnown(_ s: String) -> Bool {
        let words = EnglishRules.tokenize(s).filter { EnglishRules.isWord($0) }
        guard (2...14).contains(words.count) else { return false }
        let sc = NSSpellChecker.shared
        let miss = sc.checkSpelling(of: s, startingAt: 0, language: "en", wrap: false,
                                    inSpellDocumentWithTag: SystemGrammarEngine.tag, wordCount: nil)
        if miss.location != NSNotFound {
            let w = (s as NSString).substring(with: miss)
            if !(w.first?.isUppercase ?? false) { return false }   // unknown lowercase word
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = s
        var hasVerb = false
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if tag == .verb { hasVerb = true; return false }
            return true
        }
        return hasVerb
    }

    static func hasVerb(_ s: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = s
        var found = false
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            let w = String(s[r]).lowercased()
            let known = EnglishRules.baseVerbs.contains(w) || EnglishRules.sToBase[w] != nil
                || EnglishRules.pastToBase[w] != nil || EnglishRules.partToBase[w] != nil
                || EnglishRules.ingToBase[w] != nil || EnglishRules.beForms.contains(w) || EnglishRules.auxes.contains(w)
                || ["has", "had", "'s", "'m", "'re", "'ve", "let's", "been", "being"].contains(w)
            // NLTagger alone guesses "verb" for misheard words ("Eye age, not MN"), so confirm it.
            if known || (tag == .verb && EnglishRules.lexClass(w) == .verb) { found = true; return false }
            return true
        }
        return found
    }
    static func isGreeting(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["good morning", "good afternoon", "good evening", "good night", "hello", "hi", "hey", "thank you", "thanks",
                "bye", "welcome", "sorry", "okay", "yes", "no", "please", "congratulations", "happy birthday", "cheers"]
            .contains { l.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    static func sameWords(_ a: String, _ b: String) -> Bool {
        let (w, c) = diff(a, b)
        return w.isEmpty && c.isEmpty
    }

    static func range(of word: String, in s: String) -> NSRange? {
        let esc = NSRegularExpression.escapedPattern(for: word)
        guard let re = try? NSRegularExpression(pattern: "\\b\(esc)\\b", options: .caseInsensitive) else { return nil }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))?.range
    }

    /// Word-level LCS diff (case-insensitive, punctuation ignored).
    static func diff(_ a: String, _ b: String) -> ([NSRange], [NSRange]) {
        func words(_ s: String) -> [(String, NSRange)] {
            let re = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:'[A-Za-z]+)?")
            return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map {
                ((s as NSString).substring(with: $0.range).lowercased(), $0.range)
            }
        }
        let x = words(a), y = words(b)
        let n = x.count, m = y.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = x[i].0 == y[j].0 ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0, wrong: [NSRange] = [], changed: [NSRange] = []
        while i < n && j < m {
            if x[i].0 == y[j].0 { i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { wrong.append(x[i].1); i += 1 }
            else { changed.append(y[j].1); j += 1 }
        }
        while i < n { wrong.append(x[i].1); i += 1 }
        while j < m { changed.append(y[j].1); j += 1 }
        return (wrong, changed)
    }
}

// MARK: - Log (~/Library/Logs/GoodMorning/correct-english.log): what speech heard + what each engine said

@MainActor
enum GrammarLog {
    static var enabled = true
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/GoodMorning/correct-english.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func write(_ line: String) {
        guard enabled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: url)   // keep it small
        }
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Engine 1: Apple Intelligence (Foundation Models)

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct FMCorrection {
    @Guide(description: "The learner's sentence rewritten in correct, natural English with minimal changes and the same meaning. If it is already correct, repeat it exactly.")
    var corrected: String
    @Guide(description: "One short friendly tip (max 14 words) explaining the main fix, e.g. Use 'went' (past tense) with 'yesterday'. Empty if already correct.")
    var tip: String
}

@available(macOS 26.0, *)
@MainActor
struct AppleIntelligenceEngine: GrammarEngine {
    let name = "Apple Intelligence"
    let isAuthoritative = true
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    static var statusText: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
            case .deviceNotEligible: return "this Mac isn't eligible"
            case .modelNotReady: return "the model is still downloading"
            @unknown default: return "unavailable"
            }
        }
    }
    func check(_ text: String) async -> EngineOutput? {
        let session = LanguageModelSession(instructions: """
            You are a kind English teacher for an Indian English learner. The user spoke one English sentence \
            (speech-to-text, so ignore capitalisation and punctuation). Fix grammar, verb tense, subject-verb \
            agreement, articles, prepositions, plurals, word choice and common Indian-English errors \
            (e.g. "I am agree", "discuss about", "since 2 years", "did he went"). Keep the meaning and change \
            as little as possible. If it is already correct, repeat it exactly.
            """)
        do {
            let r = try await session.respond(to: "Sentence: \(text)", generating: FMCorrection.self,
                                              options: GenerationOptions(temperature: 0))
            let fixed = r.content.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fixed.isEmpty else { return nil }
            let tip = r.content.tip.trimmingCharacters(in: .whitespacesAndNewlines)
            return EngineOutput(text: fixed, tips: tip.isEmpty ? [] : [tip])
        } catch {
            return nil
        }
    }
}
#endif

// MARK: - Engine 2: built-in rules

@MainActor
struct RulesEngine: GrammarEngine {
    let name = "built-in rules"
    let isAuthoritative = false
    var isAvailable: Bool { true }
    func check(_ text: String) async -> EngineOutput? {
        let (s, tips) = EnglishRules.correct(text)
        return EngineOutput(text: s, tips: tips)
    }
}

// MARK: - Engine 3: macOS grammar + spelling checker (NSSpellChecker)

@MainActor
struct SystemGrammarEngine: GrammarEngine {
    let name = "macOS grammar checker"
    let isAuthoritative = false
    var isAvailable: Bool { true }
    static let tag = NSSpellChecker.uniqueSpellDocumentTag()

    func check(_ text: String) async -> EngineOutput? {
        let sc = NSSpellChecker.shared
        var s = text
        var out = EngineOutput(text: text)
        let types = NSTextCheckingResult.CheckingType.grammar.rawValue
            | NSTextCheckingResult.CheckingType.spelling.rawValue
            | NSTextCheckingResult.CheckingType.correction.rawValue
        let opts: [NSSpellChecker.OptionKey: Any] = [.orthography: NSOrthography.defaultOrthography(forLanguage: "en")]

        for _ in 0..<3 {
            let ns = s as NSString
            let results = sc.check(s, range: NSRange(location: 0, length: ns.length), types: types, options: opts,
                                   inSpellDocumentWithTag: Self.tag, orthography: nil, wordCount: nil)
            var corrections: [NSRange: String] = [:]
            for r in results where r.resultType == .correction {
                if let rep = r.replacementString { corrections[r.range] = rep }
            }
            var edits: [(NSRange, String, String)] = []
            for r in results {
                if r.resultType == .grammar {
                    for d in r.grammarDetails ?? [] {
                        guard let rv = d["NSGrammarRange"] as? NSValue else { continue }
                        let rel = rv.rangeValue
                        let abs = NSRange(location: r.range.location + rel.location, length: rel.length)
                        guard abs.length > 0, NSMaxRange(abs) <= ns.length else { continue }
                        let desc = d["NSGrammarUserDescription"] as? String ?? ""
                        if desc.localizedCaseInsensitiveContains("fragment") { continue }
                        let old = ns.substring(with: abs)
                        let conf = (d["NSGrammarConfidenceScore"] as? NSNumber)?.doubleValue ?? 1
                        if let rep = (d["NSGrammarCorrections"] as? [String])?.first, conf >= 0.8 {
                            edits.append((abs, Self.matchCase(old, rep), Self.tip(old, rep)))
                        } else {
                            out.flags.append(GrammarFlag(word: old, note: Self.note(old, desc)))
                        }
                    }
                } else if r.resultType == .spelling {
                    let word = ns.substring(with: r.range)
                    if word.first?.isUppercase == true { continue }          // probably a name
                    // Speech only produces real words, so an unknown word is usually a name (e.g. "mumbai"):
                    // apply clear autocorrections, but never flag unknown words as errors.
                    if let rep = corrections[r.range], rep.lowercased() != word.lowercased() {
                        edits.append((r.range, rep, "Spelling: ‘\(word)’ → ‘\(rep)’."))
                    }
                }
            }
            var applied = false, lastStart = Int.max
            for (range, rep, tip) in edits.sorted(by: { $0.0.location > $1.0.location })
            where NSMaxRange(range) <= lastStart {
                s = (s as NSString).replacingCharacters(in: range, with: rep)
                lastStart = range.location
                if !out.tips.contains(tip) { out.tips.append(tip) }
                applied = true
            }
            if !applied { break }
        }

        // checkGrammar sometimes notices problems check() doesn't, but without a fix → flags only.
        let ns = s as NSString
        var start = 0
        while start < ns.length {
            var details: NSArray?
            let r = sc.checkGrammar(of: s, startingAt: start, language: "en", wrap: false,
                                    inSpellDocumentWithTag: Self.tag, details: &details)
            if r.location == NSNotFound || r.length == 0 { break }
            for case let d as [String: Any] in (details as? [Any]) ?? [] {
                guard let rv = d["NSGrammarRange"] as? NSValue else { continue }
                let rel = rv.rangeValue
                let abs = NSRange(location: r.location + rel.location, length: rel.length)
                let desc = d["NSGrammarUserDescription"] as? String ?? ""
                guard abs.length > 0, NSMaxRange(abs) <= ns.length,
                      !desc.localizedCaseInsensitiveContains("fragment") else { continue }
                let word = ns.substring(with: abs)
                if !out.flags.contains(where: { $0.word == word }) {
                    out.flags.append(GrammarFlag(word: word, note: Self.note(word, desc)))
                }
            }
            start = NSMaxRange(r)
        }
        out.text = s
        return out
    }

    static func matchCase(_ old: String, _ rep: String) -> String {
        guard let f = old.first, f.isUppercase, rep != "I" else { return rep }
        return rep.prefix(1).uppercased() + rep.dropFirst()
    }
    static func tip(_ old: String, _ rep: String) -> String {
        let o = old.lowercased(), r = rep.lowercased()
        if ["a", "an"].contains(o) && ["a", "an"].contains(r) {
            return "Use ‘\(r)’ here: ‘a’ before a consonant sound, ‘an’ before a vowel sound."
        }
        if o == "its" { return "‘It's’ means ‘it is’; ‘its’ means ‘belonging to it’." }
        let verbs: Set = ["is", "are", "was", "were", "am", "has", "have", "do", "does", "don't", "doesn't"]
        if verbs.contains(o) || verbs.contains(r) {
            return "Use ‘\(r)’, not ‘\(o)’, so the verb agrees with its subject."
        }
        return "Use ‘\(r)’ instead of ‘\(o)’."
    }
    static func note(_ word: String, _ desc: String) -> String {
        if desc.localizedCaseInsensitiveContains("agree") {
            return "‘\(word)’ may not agree with the rest of the sentence."
        }
        return desc.isEmpty ? "‘\(word)’ looks wrong here." : desc
    }
}

// MARK: - Rule-based corrector for common (Indian-)English learner mistakes

@MainActor
enum EnglishRules {
    enum Person { case first, third, plural }

    static let irregularPast: [String: String] = [
        "go": "went", "come": "came", "eat": "ate", "drink": "drank", "buy": "bought", "see": "saw", "take": "took",
        "make": "made", "do": "did", "have": "had", "get": "got", "give": "gave", "tell": "told", "say": "said",
        "think": "thought", "write": "wrote", "read": "read", "meet": "met", "leave": "left", "find": "found",
        "run": "ran", "sleep": "slept", "speak": "spoke", "bring": "brought", "teach": "taught", "sit": "sat",
        "stand": "stood", "know": "knew", "feel": "felt", "pay": "paid", "send": "sent", "spend": "spent",
        "win": "won", "lose": "lost", "drive": "drove", "fly": "flew", "swim": "swam", "catch": "caught",
        "wake": "woke", "sing": "sang", "forget": "forgot", "understand": "understood", "break": "broke",
        "choose": "chose", "keep": "kept", "sell": "sold", "wear": "wore", "throw": "threw", "begin": "began",
        "hear": "heard", "put": "put", "cut": "cut", "hit": "hit", "become": "became", "grow": "grew",
        "mean": "meant", "lend": "lent", "build": "built", "hold": "held", "fall": "fell", "steal": "stole",
        "ride": "rode", "hide": "hid", "bite": "bit", "shake": "shook", "rise": "rose", "forgive": "forgave",
        "let": "let", "set": "set", "cost": "cost", "hurt": "hurt", "shut": "shut", "feed": "fed",
        "fight": "fought", "draw": "drew", "blow": "blew", "ring": "rang", "shoot": "shot", "lead": "led",
    ]
    static let participle: [String: String] = [
        "go": "gone", "come": "come", "eat": "eaten", "drink": "drunk", "see": "seen", "take": "taken",
        "do": "done", "give": "given", "write": "written", "speak": "spoken", "break": "broken",
        "choose": "chosen", "forget": "forgotten", "know": "known", "begin": "begun", "sing": "sung",
        "swim": "swum", "fly": "flown", "drive": "driven", "run": "run", "become": "become", "grow": "grown",
        "throw": "thrown", "wear": "worn", "fall": "fallen", "steal": "stolen", "ride": "ridden",
        "wake": "woken", "hide": "hidden", "bite": "bitten", "shake": "shaken", "rise": "risen",
        "forgive": "forgiven", "draw": "drawn", "blow": "blown", "ring": "rung", "be": "been",
    ]
    static let regularVerbs: Set<String> = [
        "walk", "play", "watch", "visit", "call", "cook", "study", "live", "work", "like", "love", "want", "talk",
        "open", "close", "start", "finish", "help", "clean", "use", "need", "ask", "reach", "arrive", "travel",
        "wait", "stay", "listen", "learn", "try", "cry", "carry", "move", "dance", "wash", "fix", "miss", "enjoy",
        "plan", "stop", "shop", "jump", "laugh", "look", "order", "pick", "join", "return", "change", "decide",
        "prepare", "practice", "practise", "remember", "share", "show", "smile", "agree", "believe", "hope",
        "discuss", "explain", "complete", "attend", "answer", "apply", "book", "check", "count", "create",
        "deliver", "depend", "describe", "develop", "drop", "enter", "expect", "fail", "fill", "follow", "guess",
        "happen", "hate", "improve", "include", "invite", "kiss", "lock", "manage", "marry", "mention",
        "notice", "offer", "pass", "pray", "prefer", "print", "promise", "pull", "push", "rain", "receive",
        "relax", "rent", "repair", "repeat", "reply", "report", "rest", "save", "search", "serve", "shout",
        "sign", "solve", "suggest", "support", "surprise", "switch", "thank", "touch", "train", "turn", "type",
        "warn", "waste", "wish", "worry", "borrow", "climb", "collect", "compare", "complain", "continue",
        "copy", "cross", "dress", "earn", "end", "exercise", "hurry", "kick", "knock", "land", "mix", "park",
        "perform", "plant", "pour", "protect", "rush", "smell", "taste", "test", "trust", "behave", "belong",
        "celebrate", "chat", "clap", "chase", "own", "seem", "deserve", "realize", "realise", "recognize",
        "suppose", "dream", "fry", "bake", "boil", "paint", "disagree", "understand",
    ]
    static let baseVerbs: Set<String> = regularVerbs.union(irregularPast.keys)
    static let badPast: [String: String] = [
        "goed": "went", "buyed": "bought", "eated": "ate", "runned": "ran", "comed": "came", "taked": "took",
        "maked": "made", "writed": "wrote", "speaked": "spoke", "thinked": "thought", "catched": "caught",
        "teached": "taught", "bringed": "brought", "drinked": "drank", "sleeped": "slept", "feeled": "felt",
        "leaved": "left", "telled": "told", "knowed": "knew", "gived": "gave", "getted": "got", "sitted": "sat",
        "standed": "stood", "swimmed": "swam", "drived": "drove", "flied": "flew", "falled": "fell",
        "finded": "found", "losed": "lost", "payed": "paid", "sayed": "said", "sended": "sent", "spended": "spent",
        "understanded": "understood", "winned": "won", "breaked": "broke", "choosed": "chose",
        "forgetted": "forgot", "keeped": "kept", "meeted": "met", "putted": "put", "selled": "sold",
        "throwed": "threw", "weared": "wore", "seed": "saw", "heared": "heard", "begined": "began", "cutted": "cut",
    ]
    static let apostrophes: [String: String] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "cant": "can't", "wont": "won't",
        "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't", "werent": "weren't", "im": "I'm", "ive": "I've",
        "thats": "that's", "theres": "there's", "whats": "what's", "couldnt": "couldn't", "shouldnt": "shouldn't",
        "wouldnt": "wouldn't", "havent": "haven't", "hasnt": "hasn't", "youre": "you're", "theyre": "they're",
    ]
    static let numberWords: Set<String> = ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                           "many", "several", "few", "both", "these", "those", "hundred", "thousand"]
    static let adjectives: Set<String> = ["big", "small", "good", "new", "old", "red", "blue", "green", "nice",
                                          "little", "large", "young", "beautiful", "best", "other", "different",
                                          "younger", "elder", "older", "close", "dear", "great", "whole"]
    static let placeNouns: Set<String> = ["office", "market", "station", "airport", "bank", "gym", "park", "cinema",
                                          "mall", "doctor", "shop", "temple", "beach", "hotel", "library", "museum"]
    static let subjPron: Set<String> = ["i", "you", "he", "she", "it", "we", "they"]
    static let indefinite: Set<String> = ["everybody", "everyone", "somebody", "someone", "nobody", "anybody",
                                          "anyone", "everything", "nothing", "something"]
    static let adverbs: Set<String> = ["also", "always", "never", "often", "usually", "sometimes", "really", "just",
                                       "still", "even", "already", "only", "generally", "mostly", "normally",
                                       "actually", "definitely", "probably"]
    static let dets: Set<String> = ["the", "a", "an", "my", "your", "his", "her", "our", "their", "this", "that",
                                    "these", "those", "every", "each"]
    static let auxes: Set<String> = ["do", "does", "did", "don't", "doesn't", "didn't", "can", "can't", "cannot",
                                     "could", "couldn't", "will", "won't", "would", "wouldn't", "should",
                                     "shouldn't", "must", "may", "might", "shall"]
    static let beForms: Set<String> = ["am", "is", "are", "was", "were"]
    static let wh: Set<String> = ["where", "what", "why", "when", "how", "who", "which"]
    static let timeWords: Set<String> = ["night", "week", "month", "year", "time", "sunday", "monday", "tuesday",
                                         "wednesday", "thursday", "friday", "saturday", "evening", "morning",
                                         "weekend", "summer", "winter", "day"]
    static let functionWords: Set<String> = ["the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at",
                                             "for", "with", "is", "are", "was", "were", "be", "it", "this", "that",
                                             "i", "you", "he", "she", "we", "they", "my", "your", "his", "her",
                                             "our", "their", "not", "no", "yes", "so", "very", "too", "from"]
    static let uncountable: [String: String] = [
        "informations": "information", "advices": "advice", "furnitures": "furniture", "luggages": "luggage",
        "baggages": "baggage", "equipments": "equipment", "knowledges": "knowledge", "homeworks": "homework",
        "feedbacks": "feedback", "sceneries": "scenery", "jewelleries": "jewellery", "stuffs": "stuff",
        "softwares": "software", "evidences": "evidence",
    ]

    // MARK: word forms
    static func sForm(_ v: String) -> String {
        switch v {
        case "go": return "goes"; case "do": return "does"; case "have": return "has"
        default:
            if ["s", "x", "z"].contains(String(v.suffix(1))) || v.hasSuffix("ch") || v.hasSuffix("sh") { return v + "es" }
            if v.hasSuffix("y"), let c = v.dropLast().last, !"aeiou".contains(c) { return v.dropLast() + "ies" }
            return v + "s"
        }
    }
    static let doubling: Set<String> = ["stop", "plan", "shop", "jog", "drop", "chat", "clap", "rob", "hug", "beg",
                                        "run", "swim", "sit", "get", "put", "cut", "begin", "win", "hit", "forget"]
    static func past(_ v: String) -> String {
        if let p = irregularPast[v] { return p }
        if doubling.contains(v) { return v + String(v.last!) + "ed" }
        if v.hasSuffix("e") { return v + "d" }
        if v.hasSuffix("y"), let c = v.dropLast().last, !"aeiou".contains(c) { return v.dropLast() + "ied" }
        return v + "ed"
    }
    static func ing(_ v: String) -> String {
        if v.hasSuffix("ie") { return v.dropLast(2) + "ying" }
        if v.hasSuffix("e"), !v.hasSuffix("ee"), v != "be" { return v.dropLast() + "ing" }
        if doubling.contains(v) { return v + String(v.last!) + "ing" }
        return v + "ing"
    }
    static func participleOf(_ v: String) -> String { participle[v] ?? past(v) }
    static func plural(_ n: String) -> String {
        let irregular = ["child": "children", "man": "men", "woman": "women", "person": "people",
                         "foot": "feet", "tooth": "teeth", "mouse": "mice"]
        if let p = irregular[n] { return p }
        if ["s", "x", "z"].contains(String(n.suffix(1))) || n.hasSuffix("ch") || n.hasSuffix("sh") { return n + "es" }
        if n.hasSuffix("y"), let c = n.dropLast().last, !"aeiou".contains(c) { return n.dropLast() + "ies" }
        return n + "s"
    }
    static let pastToBase: [String: String] = {
        var d: [String: String] = [:]
        for v in regularVerbs { d[past(v)] = v }
        for (b, p) in irregularPast { d[p] = b }
        return d
    }()
    static let partToBase: [String: String] = Dictionary(participle.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    static let sToBase: [String: String] = Dictionary(baseVerbs.map { (sForm($0), $0) }, uniquingKeysWith: { a, _ in a })
    static let ingToBase: [String: String] = Dictionary(baseVerbs.map { (ing($0), $0) }, uniquingKeysWith: { a, _ in a })
    static let participleOnly: Set<String> = Set(participle.values).subtracting(irregularPast.values)
        .subtracting(irregularPast.keys)
    static func isPastForm(_ w: String) -> Bool { if let b = pastToBase[w] { return b != w } else { return false } }

    static var lexCache: [String: NLTag] = [:]
    static func lexClass(_ w: String) -> NLTag? {
        let k = w.lowercased()
        if let c = lexCache[k] { return c }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = k
        let (tag, _) = tagger.tag(at: k.startIndex, unit: .word, scheme: .lexicalClass)
        if let tag { lexCache[k] = tag }
        return tag
    }
    static func isNoun(_ w: String) -> Bool {
        let k = w.lowercased()
        return !functionWords.contains(k) && !baseVerbs.contains(k) && k.count > 1 && lexClass(k) == .noun
    }
    /// After a determiner ("my sister"), any word that isn't a verb, helper or function word acts as the noun.
    /// (Tagging a single word is unreliable: NLTagger calls "sister" OtherWord and "brother" an interjection.)
    static func isNounAfterDet(_ w: String) -> Bool {
        let k = w.lowercased()
        guard k.count > 1, k.first?.isLetter == true, !functionWords.contains(k), !baseVerbs.contains(k),
              sToBase[k] == nil, pastToBase[k] == nil, partToBase[k] == nil, !beForms.contains(k),
              !auxes.contains(k), !adverbs.contains(k), !k.hasSuffix("ly"), !k.contains("'") else { return false }
        let c = lexClass(k)
        return c != .verb && c != .adverb && c != .preposition && c != .pronoun && c != .determiner
    }
    static func isPluralNoun(_ n: String) -> Bool {
        if ["children", "people", "men", "women", "feet", "teeth", "police", "mice"].contains(n) { return true }
        if ["news", "maths", "physics", "series", "bus", "class", "glass", "boss", "status"].contains(n) { return false }
        return n.count > 3 && n.hasSuffix("s") && !n.hasSuffix("ss") && !n.hasSuffix("us") && !n.hasSuffix("is")
    }

    // MARK: tokens
    static func tokenize(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:'[A-Za-z]+)?|[^\\sA-Za-z0-9]")
        var out: [String] = []
        let splitS: Set = ["he", "she", "it", "that", "there", "what", "who", "where", "here", "how"]
        for m in re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            let tok = (s as NSString).substring(with: m.range)
            let low = tok.lowercased()
            if let r = ["'m", "'re", "'ve", "'ll", "'d"].first(where: { low.hasSuffix($0) }), tok.count > r.count {
                out.append(String(tok.dropLast(r.count))); out.append(String(tok.suffix(r.count)))
            } else if low.hasSuffix("'s"), splitS.contains(String(low.dropLast(2))) {
                out.append(String(tok.dropLast(2))); out.append(String(tok.suffix(2)))
            } else {
                out.append(tok)
            }
        }
        return out
    }
    static func join(_ t: [String]) -> String {
        var out = ""
        for tok in t {
            if out.isEmpty || [".", ",", "!", "?", ";", ":"].contains(tok) || tok.hasPrefix("'") { out += tok }
            else { out += " " + tok }
        }
        return out
    }
    static func isWord(_ s: String) -> Bool { s.first.map { $0.isLetter || $0.isNumber } ?? false }
    static func keepCase(_ like: String, _ new: String) -> String {
        guard let f = like.first, f.isUppercase, like != "I" else { return new }
        return new.prefix(1).uppercased() + new.dropFirst()
    }

    // MARK: phrase rules (regex, case-insensitive). Tip templates may use $1, $2…
    struct Phrase { let re: NSRegularExpression; let template: String; let tip: String; let since: Bool }
    static let phrases: [Phrase] = {
        let raw: [(String, String, String, Bool)] = [
            (#"\b(discuss(?:es|ed|ing)?)\s+about\b"#, "$1", "Say ‘discuss something’ — ‘discuss’ needs no ‘about’.", false),
            (#"\brevert(?:s|ed|ing)?\s+back\s+to\s+(me|us|him|her|them)\b"#, "reply to $1", "To answer someone, say ‘reply to $1’ — ‘revert back’ isn't standard English.", false),
            (#"\b(return(?:s|ed|ing)?|revert(?:s|ed|ing)?)\s+back\b"#, "$1", "‘$1’ already means ‘back’ — drop ‘back’.", false),
            (#"\b(repeat(?:s|ed|ing)?)\s+again\b"#, "$1", "‘Repeat’ already means ‘again’.", false),
            (#"\b(cope(?:s|d)?|coping)\s+up\s+with\b"#, "$1 with", "Say ‘cope with’ (no ‘up’).", false),
            (#"\b(emphasi[sz]e(?:s|d)?)\s+on\b"#, "$1", "‘Emphasize’ takes no ‘on’.", false),
            (#"\b(comprise(?:s|d)?)\s+of\b"#, "$1", "Say ‘comprises’ or ‘consists of’, not ‘comprises of’.", false),
            (#"\b(can|could)\s+(?:be\s+)?able\s+to\b"#, "$1", "Use ‘can’ or ‘be able to’ — not both together.", false),
            (#"\b(?:much\s+)?more\s+(better|worse|bigger|smaller|taller|shorter|older|younger|faster|slower|easier|harder|cheaper|stronger|longer|higher|lower|nicer|happier|richer|larger|greater|smarter|busier|heavier|lighter|wiser|safer|hotter|colder|warmer|cooler|elder)\b"#, "$1", "‘$1’ is already a comparative — drop ‘more’.", false),
            (#"\bmost\s+(best|worst|biggest|smallest|tallest|oldest|youngest|fastest|easiest|cheapest|strongest|highest|nicest|happiest|richest|largest|greatest|smartest)\b"#, "$1", "‘$1’ is already a superlative — drop ‘most’.", false),
            (#"\belder\s+than\b"#, "older than", "Use ‘older than’ — ‘elder’ isn't used with ‘than’.", false),
            (#"\b(senior|junior|superior|inferior)\s+than\b"#, "$1 to", "Say ‘$1 to’, not ‘$1 than’.", false),
            (#"\b(prefer(?:s|red)?)\b(.{1,40}?)\bthan\b"#, "$1$2to", "Say ‘prefer A to B’ (not ‘than’).", false),
            (#"\b(marri(?:ed|es)|marry|marrying)\s+with\b"#, "$1", "You ‘marry someone’ — no ‘with’.", false),
            (#"\b(go|goes|went|going|gone|come|comes|came|coming|get|gets|got|getting|reach(?:es|ed|ing)?|return(?:s|ed|ing)?)\s+to\s+home\b"#, "$1 home", "Say ‘$1 home’ — no ‘to’ before ‘home’.", false),
            (#"\b(reach(?:es|ed|ing)?)\s+to\b"#, "$1", "‘Reach’ needs no ‘to’: ‘I reached home’.", false),
            (#"\bborrow\s+(me|him|her|us|them)\b"#, "lend $1", "You ‘lend’ something to someone; you ‘borrow’ from someone.", false),
            (#"\bborrowed\s+(me|him|her|us|them)\b"#, "lent $1", "You ‘lend’ something to someone; you ‘borrow’ from someone.", false),
            (#"\b(explain(?:s|ed)?)\s+(me|him|her|us|them)\s+(the\s+\w+|this|that|it|everything|my\s+\w+|his\s+\w+|her\s+\w+|your\s+\w+|our\s+\w+|their\s+\w+)"#, "$1 $3 to $2", "Say ‘explain something to $2’.", false),
            (#"\b(told|tell|tells|telling)\s+to\s+(me|him|her|us|them)\b"#, "$1 $2", "Say ‘$1 $2’ — no ‘to’.", false),
            (#"\bsaid\s+(me|him|her|us|them)\b"#, "told $1", "Use ‘told $1’ — ‘say’ isn't followed by a person.", false),
            (#"\b(listen(?:s|ed|ing)?)\s+(music|songs?|the\s+radio|me|him|her|them|us|my|your|his)\b"#, "$1 to $2", "Say ‘listen to …’.", false),
            (#"\b(wait(?:s|ed|ing)?)\s+(you|me|him|her|them|us)\b"#, "$1 for $2", "Say ‘wait for $2’.", false),
            (#"\b(afraid|scared)\s+from\b"#, "$1 of", "Say ‘$1 of’.", false),
            (#"\binterested\s+(?:for|on)\b"#, "interested in", "Say ‘interested in’.", false),
            (#"\b(good|bad|better|weak|expert)\s+in\s+(maths?|english|cricket|sports?|cooking|singing|dancing|drawing|studies)\b"#, "$1 at $2", "Say ‘$1 at $2’.", false),
            (#"\b(enter(?:s|ed|ing)?)\s+into\s+(the\s+)?(room|house|class|classroom|office|building|hall)\b"#, "$1 $2$3", "‘Enter’ needs no ‘into’.", false),
            (#"\b(?:in|at)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, "on $1", "Use ‘on’ with days: ‘on $1’.", false),
            (#"\b(?:at|on)\s+(morning|evening|afternoon)\b"#, "in the $1", "Say ‘in the $1’.", false),
            (#"\bin\s+(?:the\s+)?night\b"#, "at night", "Say ‘at night’.", false),
            (#"\bvery\s+much\s+(happy|sad|good|bad|tired|excited|busy|glad|beautiful|nice|important|angry|worried|thankful|grateful|interested)\b"#, "very $1", "Say ‘very $1’ (not ‘very much $1’).", false),
            (#"\bsince\s+(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|many|several|a\s+few|few)\s+(years?|months?|weeks?|days?|hours?|minutes?)\b"#, "for $1 $2", "Use ‘for’ with a length of time (for $1 $2); ‘since’ needs a starting point (since 2019).", true),
            (#"\b(am|is|are|'m|'re|'s|have\s+been|has\s+been)\s+(\w+ing)\b(.{0,40}?)\bfrom\s+((?:19|20)\d\d|morning|yesterday|childhood|last\s+\w+|(?:mon|tues|wednes|thurs|fri|satur|sun)day)\b"#, "$1 $2$3since $4", "Use ‘since’ with a starting point: ‘since $4’.", true),
            (#"\b(know|knew|live|lived|work|worked|stay|stayed)\b(.{0,30}?)\bfrom\s+((?:19|20)\d\d|childhood)\b"#, "$1$2since $3", "Use ‘since’ with a starting point: ‘since $3’.", true),
            (#"^\s*myself\s+(?:is\s+)?([a-z]+)\b(?!\s+(?:am|is|was|will|can|have|did|do|went|go|feel|felt|think))"#, "I am $1", "Introduce yourself with ‘I am $1’ or ‘My name is $1’.", false),
            (#"\bits\s+(not|very|so|too|raining|snowing|getting|going|a|an|the|time|true|fine|okay|ok|late|early|cold|hot|good|bad|nice|easy|hard|difficult|important|possible|impossible)\b"#, "it's $1", "‘It's’ means ‘it is’; ‘its’ means ‘belonging to it’.", false),
            (#"^\s*me\s+and\s+(my|his|her|our|your)\s+(\w+)"#, "$1 $2 and I", "Say ‘$1 $2 and I …’ when you are the subject.", false),
            (#"^\s*me\s+and\s+(?!him\b|her\b|them\b)([A-Za-z]+)\s+(went|go|are|were|will|have|had|did|like|love|want|play|played|was|is|am)\b"#, "$1 and I $2", "Say ‘$1 and I …’ when you are the subject.", false),
            (#"\bhow\s+much\s+(books|people|friends|apples|students|children|times|days|years|hours|cars|rooms|questions|chapters|pages|languages|brothers|sisters|members|tickets|eggs|bananas|kids|chapatis|rotis|movies|songs)\b"#, "how many $1", "Use ‘how many’ with things you can count.", false),
        ]
        return raw.map { Phrase(re: try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]),
                                template: $0.1, tip: $0.2, since: $0.3) }
    }()

    // MARK: main
    static func correct(_ text: String) -> (String, [String]) {
        var tips: [String] = [], minorTips: [String] = []
        func tip(_ s: String) { if !tips.contains(s) { tips.append(s) } }
        func minor(_ s: String) { if !minorTips.contains(s) { minorTips.append(s) } }

        // 0. Phrase rules on the raw string
        // Speech recognition sprinkles commas ("Yesterday, I go…", "I am waiting, you"): ignore them.
        var str = text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: ",", with: "")
        var sinceFlag = false
        for p in phrases {
            let ms = p.re.matches(in: str, range: NSRange(location: 0, length: (str as NSString).length))
            for m in ms.reversed() {
                let rep = p.re.replacementString(for: m, in: str, offset: 0, template: p.template)
                let tipText = p.re.replacementString(for: m, in: str, offset: 0, template: p.tip)
                str = (str as NSString).replacingCharacters(in: m.range, with: rep)
                tip(tipText)
                if p.since { sinceFlag = true }
            }
        }

        var t = tokenize(str)
        func lc(_ i: Int) -> String {
            guard i >= 0 && i < t.count else { return "" }
            switch t[i].lowercased() {
            case "'m": return "am"; case "'re": return "are"; case "'ve": return "have"
            case "'ll": return "will"; case "'d": return "would"; case "'s": return "is"
            case let w: return w
            }
        }
        func wordCount() -> Int { t.filter(isWord).count }
        func endQuestion() { if t.last == "." { t[t.count - 1] = "?" } else if t.last != "?" { t.append("?") } }

        // 1. Spoken-text cleanup
        var i = 0
        while i < t.count {
            let w = lc(i)
            if let a = apostrophes[w] { t[i] = keepCase(t[i], a); minor("Add the apostrophe: ‘\(a)’.") }
            else if w == "i" { t[i] = "I" }
            else if let p = badPast[w] { t[i] = keepCase(t[i], p); tip("‘\(w)’ isn't a word — use ‘\(p)’.") }
            if i > 0, isWord(t[i]), lc(i) == lc(i - 1), !["that", "had"].contains(lc(i)) { t.remove(at: i); continue }
            i += 1
        }

        // 2. "Me and him is …" → "He and I are …"
        if t.count >= 4, lc(0) == "me", lc(1) == "and", let subj = ["him": "He", "her": "She", "them": "They"][lc(2)] {
            t[0] = subj; t[2] = "I"
            tip("Say ‘\(subj) and I’ as the subject.")
        }

        // 3. "Their is/are" → "There is/are"
        for k in t.indices where lc(k) == "their" && beForms.contains(lc(k + 1)) {
            t[k] = keepCase(t[k], "there"); tip("Use ‘there is/are’ (not ‘their’).")
        }

        func personOf(_ k: Int, be: String? = nil) -> Person {
            let s = lc(k)
            if s == "i" { return lc(k - 1) == "and" ? .plural : .first }
            if ["he", "she", "it", "this", "that", "each"].contains(s) || indefinite.contains(s) { return .third }
            if ["you", "we", "they", "these", "those"].contains(s) { return .plural }
            if k >= 0, k < t.count, isWord(t[k]), s.count > 1, isNoun(s) || t[k].first?.isUppercase == true {
                return isPluralNoun(s) ? .plural : .third
            }
            switch be { case "am": return .first; case "are", "were": return .plural; default: return .third }
        }

        // 4. Questions: "Where you are going?" / "What you want?" / "Where you went?" / "Hey how now you are doing?"
        let interjections: Set = ["hey", "hi", "hello", "so", "okay", "ok", "well", "oh", "and", "but", "please"]
        let qAdverbs: Set = ["now", "then", "really", "exactly", "actually", "today", "here", "there"]
        var q = 0
        while q < t.count, interjections.contains(lc(q)) { q += 1 }
        let endsQ = t.last == "?"
        if wh.contains(lc(q)) {
            var pIdx = q + 1
            var moved: [String] = []
            while pIdx < t.count, qAdverbs.contains(lc(pIdx)), subjPron.contains(lc(pIdx + 1)) || qAdverbs.contains(lc(pIdx + 1)) {
                moved.append(t[pIdx]); pIdx += 1
            }
            if pIdx + 1 < t.count, subjPron.contains(lc(pIdx)) {
                let v = lc(pIdx + 1)
                let rest = (min(pIdx + 2, t.count)..<t.count).map { lc($0) }
                let short = wordCount() - q <= 6 && !rest.contains(where: { beForms.contains($0) })
                var changed = false
                if beForms.contains(v) && (endsQ || short || lc(pIdx + 2).hasSuffix("ing")) {
                    t.remove(at: pIdx + 1); t.insert(v, at: pIdx)
                    tip("In a question, put the verb before the subject: ‘\(lc(q)) \(v) \(lc(pIdx + 1))…?’")
                    changed = true
                } else if endsQ || short {
                    var base: String?, aux = ""
                    if isPastForm(v) { base = pastToBase[v]; aux = "did" }
                    else if baseVerbs.contains(v) { base = v; aux = personOf(pIdx) == .third ? "does" : "do" }
                    else if let b = sToBase[v] { base = b; aux = "does" }
                    if let b = base {
                        t[pIdx + 1] = b; t.insert(aux, at: pIdx)
                        tip("Questions need a helper verb: ‘\(lc(q)) \(aux) \(lc(pIdx + 1)) \(b)…?’")
                        changed = true
                    }
                }
                if changed {
                    if !moved.isEmpty {   // "how now you are doing" → "how are you doing now"
                        t.removeSubrange((q + 1)..<(q + 1 + moved.count))
                        if let last = t.last, [".", "?", "!"].contains(last) { t.insert(contentsOf: moved.map { $0.lowercased() }, at: t.count - 1) }
                        else { t.append(contentsOf: moved.map { $0.lowercased() }) }
                    }
                    endQuestion()
                }
            }
        }

        // 5. be + stative verb ("I am agree", "I am not agree")
        let stative: Set = ["agree", "disagree", "know", "understand", "believe", "want", "need", "hate", "prefer",
                            "remember", "belong", "depend", "own", "deserve", "realize", "realise", "recognize", "suppose"]
        i = 1
        while i < t.count {
            let be = lc(i)
            if beForms.contains(be) {
                var j = i + 1, neg = false
                if lc(j) == "not" { neg = true; j += 1 }
                if j < t.count, stative.contains(lc(j)) {
                    let v = lc(j), p = personOf(i - 1, be: be), wasPast = ["was", "were"].contains(be)
                    let rep: [String] = neg ? [wasPast ? "didn't" : (p == .third ? "doesn't" : "don't"), v]
                                            : [wasPast ? past(v) : (p == .third ? sForm(v) : v)]
                    t.replaceSubrange(i...j, with: rep)
                    tip("Say ‘\(t[i - 1]) \(rep.joined(separator: " "))’ — ‘\(v)’ is already a verb, so drop ‘\(be)’.")
                }
            }
            i += 1
        }

        // 6. be + stative -ing ("I am having two sisters", "He is knowing", "I am not knowing")
        let statIng: [String: String] = Dictionary(
            (stative.union(["like", "love", "have", "mean", "seem", "contain"])).map { (ing($0), $0) },
            uniquingKeysWith: { a, _ in a })
        let havingOK: Set = ["lunch", "dinner", "breakfast", "tea", "coffee", "fun", "party", "bath", "shower", "meal",
                             "snack", "trouble", "problems", "difficulty", "issues", "a", "an", "some", "food", "rest"]
        i = 1
        while i < t.count {
            let be = lc(i)
            if beForms.contains(be) {
                var j = i + 1, neg = false
                if lc(j) == "not" { neg = true; j += 1 }
                if j < t.count, let v = statIng[lc(j)], !(lc(j) == "having" && havingOK.contains(lc(j + 1))) {
                    let p = personOf(i - 1, be: be), wasPast = ["was", "were"].contains(be)
                    let rep: [String] = neg ? [wasPast ? "didn't" : (p == .third ? "doesn't" : "don't"), v]
                                            : [wasPast ? past(v) : (p == .third ? sForm(v) : v)]
                    let old = (i...j).map { lc($0) }.joined(separator: " ")
                    t.replaceSubrange(i...j, with: rep)
                    tip("Use ‘\(rep.joined(separator: " "))’, not ‘\(old)’ — ‘\(v)’ isn't used in the -ing form here.")
                }
            }
            i += 1
        }

        // 7. Helper/modal verb + wrong form: "didn't went", "can speaks", "will going", "Did he went?"
        let modals = auxes.subtracting(["do", "does", "did", "don't", "doesn't", "didn't"])
        for k in t.indices where auxes.contains(lc(k)) {
            var j = k + 1, hops = 0
            while hops < 3, j < t.count, subjPron.contains(lc(j)) || lc(j) == "not" || adverbs.contains(lc(j)) {
                j += 1; hops += 1
            }
            if hops == 0, dets.contains(lc(j)), j + 2 < t.count { j += 2 }   // "Did your brother went"
            guard j < t.count else { continue }
            let v = lc(j)
            var base: String? = isPastForm(v) ? pastToBase[v] : sToBase[v]
            if base == nil, modals.contains(lc(k)), let b = ingToBase[v] { base = b }
            guard let b = base, b != v else { continue }
            t[j] = keepCase(t[j], b)
            tip("After ‘\(lc(k))’, use the base verb ‘\(b)’, not ‘\(v)’.")
        }

        // 8. have/has/had + simple past → past participle ("has went" → "has gone")
        for k in t.indices where ["have", "has", "had", "haven't", "hasn't", "hadn't"].contains(lc(k)) {
            var j = k + 1
            if ["not", "never", "already", "just", "ever", "also"].contains(lc(j)) { j += 1 }
            guard j < t.count else { continue }
            let v = lc(j)
            if let b = pastToBase[v], let p = participle[b], p != v {
                t[j] = p; tip("After ‘\(lc(k))’, use ‘\(p)’ (past participle), not ‘\(v)’.")
            }
            // "I have finish my homework" → "I have finished" (skip words that are also nouns: "I have work to do")
            let nounish: Set = ["work", "love", "help", "rest", "need", "hope", "use", "plan", "book", "call", "dream",
                                "order", "change", "test", "report", "answer", "show", "taste", "trust", "doubt", "fun",
                                "time", "lunch", "dinner", "breakfast", "class", "fever", "cold"]
            if ["have", "has"].contains(lc(k)), baseVerbs.contains(v), !nounish.contains(v), !["to", "a", "an", "the"].contains(lc(j + 1)),
               !["have", "be", "do"].contains(v) {
                let p = participleOf(v)
                if p != v { t[j] = p; tip("After ‘\(lc(k))’, use ‘\(p)’ (past participle), not ‘\(v)’.") }
            }
        }

        // Subjects + their verbs (recomputed when needed)
        func isClauseStart(_ k: Int) -> Bool {
            if k == 0 { return true }
            let p = lc(k - 1)
            if [",", "but", "because", "although", "though", "while", "so", ";", "when", "if", "and", "yesterday",
                "tomorrow", "today", "ago", "tonight"].contains(p) { return true }
            return k >= 2 && ["last", "next", "every", "this"].contains(lc(k - 2)) && timeWords.contains(p)
        }
        func verbAfter(_ k: Int) -> Int {
            var j = k + 1
            while j < t.count, adverbs.contains(lc(j)) { j += 1 }
            return j
        }
        struct Slot { let subj: Int; let verb: Int; let person: Person; let inverted: Bool }
        let notNameStarts: Set = ["yesterday", "tomorrow", "today", "last", "next", "please", "let's", "let", "myself",
                                  "one", "there", "here", "every", "everyday", "kindly", "tonight", "thank", "thanks"]
        func slots() -> [Slot] {
            var out: [Slot] = []
            for k in t.indices {
                let s = lc(k)
                let inverted = k > 0 && (auxes.contains(lc(k - 1)) || beForms.contains(lc(k - 1))
                                         || ["have", "has", "had", "will"].contains(lc(k - 1)))
                if subjPron.contains(s) || indefinite.contains(s) {
                    if ["it", "you"].contains(s), !(isClauseStart(k) || wh.contains(lc(k - 1))) { continue }
                    out.append(Slot(subj: k, verb: verbAfter(k), person: personOf(k), inverted: inverted))
                } else if isClauseStart(k) {
                    // Noun phrase at the start of a clause: det (adj…) noun, or a capitalised name
                    var m = k
                    if dets.contains(s) {
                        m += 1
                        var adj = 0
                        while adj < 2, m + 1 < t.count,
                              adjectives.contains(lc(m)) || (lexClass(lc(m)) == .adjective && isNounAfterDet(lc(m + 1))) { m += 1; adj += 1 }
                        guard m < t.count, isWord(t[m]), isNounAfterDet(lc(m)) else { continue }
                    } else {
                        guard isWord(t[k]), t[k].first?.isUppercase == true, t[k] != "I", s.count > 1,
                              !functionWords.contains(s), !wh.contains(s), !auxes.contains(s), !beForms.contains(s),
                              !baseVerbs.contains(s), !indefinite.contains(s), !notNameStarts.contains(s),
                              !adverbs.contains(s), isNoun(s) || lexClass(s) == .personalName else { continue }
                    }
                    let n = lc(m)
                    let plural = ["these", "those"].contains(s) || isPluralNoun(n)
                    out.append(Slot(subj: m, verb: verbAfter(m), person: plural ? .plural : .third, inverted: inverted))
                }
            }
            return out
        }
        var cid: [Int] = []
        var pastClauses = Set<Int>(), futureClauses = Set<Int>(), marker: [Int: String] = [:]
        func findMarkers() {
            var id = 0
            cid = t.indices.map { k in
                if [",", "but", "because", "although", "though", "while", ";", "so"].contains(lc(k)) { id += 1 }
                return id
            }
            pastClauses = []; futureClauses = []; marker = [:]
            for k in t.indices {
                let w = lc(k)
                if w == "yesterday" || w == "ago" { pastClauses.insert(cid[k]); marker[cid[k]] = w }
                else if w == "last", timeWords.contains(lc(k + 1)) { pastClauses.insert(cid[k]); marker[cid[k]] = "last \(lc(k + 1))" }
                else if w == "tomorrow" { futureClauses.insert(cid[k]); marker[cid[k]] = w }
                else if w == "next", timeWords.contains(lc(k + 1)) { futureClauses.insert(cid[k]); marker[cid[k]] = "next \(lc(k + 1))" }
            }
            let both = pastClauses.intersection(futureClauses)
            pastClauses.subtract(both); futureClauses.subtract(both)
        }

        // 9. "I seen it" → "I have seen it" (or "I saw it" with a past-time word)
        findMarkers()
        for s in slots().reversed() where !s.inverted && s.verb < t.count && participleOnly.contains(lc(s.verb)) {
            let p = lc(s.verb), b = partToBase[p] ?? p
            if pastClauses.contains(cid[s.subj]) {
                t[s.verb] = past(b); tip("Use ‘\(past(b))’ (past tense) — ‘\(p)’ needs ‘have’.")
            } else {
                let h = s.person == .third ? "has" : "have"
                t.insert(h, at: s.verb); tip("‘\(p)’ needs ‘\(h)’: ‘\(h) \(p)’.")
            }
        }

        // 10. Tense from time words + subject–verb agreement
        findMarkers()
        for s in slots().reversed() where !s.inverted {
            let j = s.verb
            guard j < t.count, s.subj < cid.count else { continue }
            let v = lc(j), c = cid[s.subj]
            if pastClauses.contains(c) {
                let mk = marker[c] ?? "the past-time word"
                if ["have", "has"].contains(v), j + 1 < t.count {
                    let nx = lc(j + 1)
                    let b = partToBase[nx] ?? (isPastForm(nx) ? pastToBase[nx] : nil)
                    if let b {
                        let pv = past(b)
                        t.remove(at: j); t[j] = pv
                        tip("With ‘\(mk)’, use the simple past: ‘\(pv)’ (not ‘\(v) \(nx)’).")
                        continue
                    }
                }
                var nv: String?
                if baseVerbs.contains(v) && !isPastForm(v) && !["read", "put", "cut", "hit", "let", "set", "cost", "hurt", "shut"].contains(v) { nv = past(v) }
                else if let b = sToBase[v] { nv = past(b) }
                else if v == "am" || v == "is" { nv = "was" }
                else if v == "are" { nv = "were" }
                else if v == "don't" || v == "doesn't" { nv = "didn't" }
                else if v == "has" { nv = "had" }
                else if v == "can" { nv = "could" }
                else if v == "can't" { nv = "couldn't" }
                if let nv, nv != v { t[j] = nv; tip("Use ‘\(nv)’ (past tense) with ‘\(mk)’.") }
            } else if futureClauses.contains(c) {
                let mk = marker[c] ?? "a future time word"
                if isPastForm(v), let b = pastToBase[v] {
                    t[j] = b; t.insert("will", at: j)
                    tip("Use ‘will \(b)’ for the future (with ‘\(mk)’).")
                } else if v == "was" || v == "were" {
                    t[j] = "be"; t.insert("will", at: j)
                    tip("Use ‘will be’ for the future (with ‘\(mk)’).")
                }
            } else {
                if lc(s.subj) == "i" && v == "were" { continue }
                var nv: String?
                switch s.person {
                case .third:
                    switch v {
                    case "have": nv = "has"; case "do": nv = "does"; case "don't": nv = "doesn't"
                    case "are", "am": nv = "is"; case "were": nv = "was"; case "aren't": nv = "isn't"
                    case "weren't": nv = "wasn't"; case "haven't": nv = "hasn't"
                    default: if baseVerbs.contains(v) && !isPastForm(v) { nv = sForm(v) }
                    }
                case .first:
                    switch v {
                    case "is", "are": nv = "am"; case "has": nv = "have"; case "does": nv = "do"
                    case "doesn't": nv = "don't"; case "hasn't": nv = "haven't"
                    default: if let b = sToBase[v], b != v { nv = b }
                    }
                case .plural:
                    switch v {
                    case "is", "am": nv = "are"; case "has": nv = "have"; case "does": nv = "do"
                    case "doesn't": nv = "don't"; case "was": nv = "were"; case "isn't": nv = "aren't"
                    case "wasn't": nv = "weren't"; case "hasn't": nv = "haven't"
                    default: if let b = sToBase[v], b != v { nv = b }
                    }
                }
                if let nv, nv != v {
                    t[j] = keepCase(t[j], nv)
                    let subj = t[s.subj]
                    tip("Use ‘\(subj) \(nv)’" + (s.person == .third && nv.hasSuffix("s") && !["is", "was"].contains(nv)
                        ? " — he/she/it and singular nouns take -s." : " so the verb agrees with ‘\(subj)’."))
                }
            }
        }
        // In a past clause, a bare verb after "and" keeps the tense ("went to the market and buy" → "bought")
        findMarkers()
        for k in t.indices where k > 0 && lc(k - 1) == "and" && pastClauses.contains(cid[k]) {
            let v = lc(k)
            if baseVerbs.contains(v) && !isPastForm(v) && (0..<k).contains(where: { cid[$0] == cid[k] && isPastForm(lc($0)) }) {
                t[k] = past(v); tip("Keep the past tense: ‘\(past(v))’.")
            }
        }

        // 11. "There is many / two …" → "There are"
        for k in t.indices where lc(k) == "there" && ["is", "was"].contains(lc(k + 1)) {
            let q = lc(k + 2)
            if numberWords.contains(q) || (!q.isEmpty && q.allSatisfy(\.isNumber) && q != "1")
                || (q == "some" && isPluralNoun(lc(k + 3))) || (q == "so" && lc(k + 3) == "many") {
                let nv = lc(k + 1) == "is" ? "are" : "were"
                t[k + 1] = nv; tip("Use ‘there \(nv)’ with plural nouns.")
            }
        }

        // 12. Plurals: after numbers, and "one of my friend"
        for k in t.indices where numberWords.contains(lc(k))
            || (!lc(k).isEmpty && lc(k).allSatisfy(\.isNumber) && lc(k) != "1" && lc(k).count < 4) {
            var j = k + 1
            if adjectives.contains(lc(j)) { j += 1 }
            let n = lc(j)
            guard j < t.count, isWord(t[j]), n.count > 2, !isPluralNoun(n), !n.hasSuffix("s"),
                  !["of", "more", "times", "and", "or", "the", "pm", "am", "percent", "people", "children"].contains(n),
                  !baseVerbs.contains(n), isNoun(n) else { continue }
            let p = plural(n)
            t[j] = keepCase(t[j], p); tip("Use the plural ‘\(p)’ after ‘\(lc(k))’.")
        }
        for k in t.indices where lc(k) == "one" && lc(k + 1) == "of"
            && ["my", "his", "her", "our", "their", "the", "your", "these", "those"].contains(lc(k + 2)) {
            var j = k + 3
            if adjectives.contains(lc(j)) { j += 1 }
            let n = lc(j)
            guard j < t.count, isWord(t[j]), !n.hasSuffix("s"), isNoun(n) else { continue }
            t[j] = plural(n); tip("After ‘one of my …’, use a plural: ‘\(plural(n))’.")
        }

        // 13. Uncountable nouns ("informations", "many advices")
        for k in t.indices {
            guard let sing = uncountable[lc(k)] else { continue }
            t[k] = sing
            if lc(k - 1) == "many" { t[k - 1] = "a lot of" }
            else if ["a", "an"].contains(lc(k - 1)) { t[k - 1] = "some" }
            tip("‘\(sing)’ is uncountable — no -s (say ‘a lot of \(sing)’ or ‘some \(sing)’).")
        }

        // 14. Articles: a/an by sound, and "go to market" → "go to the market"
        let anWords: Set = ["hour", "hours", "honest", "honour", "honor", "heir", "hourly", "honestly", "honorable"]
        func vowelSound(_ w: String) -> Bool {
            if anWords.contains(w) { return true }
            guard let f = w.first, "aeiou".contains(f) else { return false }
            for p in ["uni", "use", "usu", "eu", "one", "once", "ute", "uti", "ure"] where w.hasPrefix(p) { return false }
            return true
        }
        for k in t.indices where ["a", "an"].contains(lc(k)) && k + 1 < t.count && isWord(t[k + 1])
            && t[k + 1].first?.isLetter == true && !(t[k + 1].count > 1 && t[k + 1] == t[k + 1].uppercased()) {
            let want = vowelSound(lc(k + 1)) ? "an" : "a"
            if lc(k) != want {
                t[k] = keepCase(t[k], want)
                tip("Use ‘\(want) \(lc(k + 1))’: ‘a’ before a consonant sound, ‘an’ before a vowel sound.")
            }
        }
        i = 0
        while i < t.count {
            if ["to", "at", "from", "in"].contains(lc(i)), placeNouns.contains(lc(i + 1)) {
                t.insert("the", at: i + 1); tip("Add ‘the’: ‘\(lc(i)) the \(lc(i + 2))’.")
                i += 2; continue
            }
            i += 1
        }

        // 15. Double negatives
        let negatives: Set = ["don't", "doesn't", "didn't", "can't", "won't", "isn't", "aren't", "wasn't", "weren't",
                              "haven't", "hasn't", "never", "not", "couldn't", "shouldn't", "wouldn't", "cannot"]
        let negFix = ["no": "any", "nothing": "anything", "nobody": "anybody", "nowhere": "anywhere", "none": "any"]
        for k in t.indices where negatives.contains(lc(k)) {
            var j = k + 1
            while j < t.count, j <= k + 3, isWord(t[j]) {
                if let f = negFix[lc(j)] {
                    t[j] = f; tip("Don't use two negatives: ‘\(lc(k)) … \(f)’."); break
                }
                j += 1
            }
        }

        // 16. "since <start>" → present perfect ("I am waiting since morning" → "I have been waiting")
        let sinceStart: Set = ["morning", "childhood", "yesterday", "last", "monday", "tuesday", "wednesday", "thursday",
                               "friday", "saturday", "sunday", "january", "february", "march", "april", "may", "june",
                               "july", "august", "september", "october", "november", "december", "then", "school",
                               "college", "my", "the", "evening", "afternoon", "night"]
        let sinceIdx = t.indices.first { lc($0) == "since" && (sinceStart.contains(lc($0 + 1)) || lc($0 + 1).first?.isNumber == true) }
        let forIdx = sinceFlag ? t.indices.first { lc($0) == "for" || lc($0) == "since" } : nil
        if let limit = sinceIdx ?? forIdx {
            for s in slots().reversed() where !s.inverted && s.verb < limit {
                let j = s.verb, v = lc(j)
                let h = s.person == .third ? "has" : "have"
                if ["am", "is", "are"].contains(v) {
                    let ingForm = lc(j + 1).hasSuffix("ing") && lc(j + 1).count > 4
                    t[j] = "been"; t.insert(h, at: j)
                    tip(ingForm ? "Use ‘\(h) been \(lc(j + 2))’ for something that started in the past and is still going on."
                                : "With ‘since’, use ‘\(h) been’.")
                } else if ["have", "has"].contains(v), lc(j + 1) == "been" || partToBase[lc(j + 1)] != nil
                            || isPastForm(lc(j + 1)) || lc(j + 1).hasSuffix("ed") {
                    continue   // already present perfect
                } else if let b = (baseVerbs.contains(v) ? v : sToBase[v]),
                          ["know", "live", "work", "stay", "study", "teach", "have", "want", "like", "love", "use", "own", "believe"].contains(b) {
                    let p = participleOf(b)
                    t[j] = p; t.insert(h, at: j)
                    tip("With ‘since’/‘for’, use the present perfect: ‘\(h) \(p)’.")
                }
            }
        }

        // 17. "everyday" as an adverb
        for k in t.indices where lc(k) == "everyday" && (k + 1 >= t.count || !isWord(t[k + 1])) {
            t[k] = "every day"; tip("‘Every day’ (two words) means daily.")
        }

        // 18. Capital letter + end punctuation
        var s = join(t)
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        if let l = s.last, !".!?".contains(l) { s += "." }
        return (s, tips + minorTips)
    }
}
