import Foundation
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - "Correct my English" engine (on-device only)

struct CorrectionResult: Equatable {
    let original: String
    let corrected: String
    let tip: String
    let wrong: [NSRange]      // ranges in `original` that were wrong (struck through)
    let changed: [NSRange]    // ranges in `corrected` that are new/fixed (highlighted)
    let isCorrect: Bool
    let engine: String
}

enum GrammarCoach {
    /// Apple Intelligence (Foundation Models) when available, otherwise built-in rules + NSSpellChecker.
    static func check(_ text: String) async -> CorrectionResult {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let (fixed, tip) = await FMCorrector.correct(original) {
            return build(original, fixed, tip: tip, engine: "Apple Intelligence (on-device)")
        }
        #endif
        let (fixed, tips) = await MainActor.run { EnglishRules.correct(original) }
        return build(original, fixed, tip: tips.first ?? "", engine: "built-in grammar rules")
    }

    static var engineName: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), FMCorrector.isAvailable { return "Apple Intelligence (on-device)" }
        #endif
        return "built-in grammar rules"
    }

    static func build(_ original: String, _ fixed: String, tip: String, engine: String) -> CorrectionResult {
        let (wrong, changed) = diff(original, fixed)
        let ok = wrong.isEmpty && changed.isEmpty
        return CorrectionResult(original: original, corrected: ok ? original : fixed, tip: ok ? "" : tip,
                                wrong: wrong, changed: changed, isCorrect: ok, engine: engine)
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

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct FMCorrection {
    @Guide(description: "The learner's sentence rewritten in correct, natural English with minimal changes and the same meaning. If it is already correct, repeat it exactly.")
    var corrected: String
    @Guide(description: "One short friendly tip (max 12 words) explaining the main fix, e.g. Use 'went' (past tense) with 'yesterday'. Empty if already correct.")
    var tip: String
}

@available(macOS 26.0, *)
enum FMCorrector {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    static func correct(_ text: String) async -> (String, String)? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You are a kind English teacher. The user spoke one English sentence (speech-to-text, so ignore \
            capitalisation and missing punctuation). Fix grammar, verb tense, articles, plurals, word choice \
            and spelling. Keep the meaning and change as little as possible.
            """)
        do {
            let r = try await session.respond(to: "Sentence: \(text)", generating: FMCorrection.self,
                                              options: GenerationOptions(temperature: 0))
            let fixed = r.content.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            return fixed.isEmpty ? nil : (fixed, r.content.tip)
        } catch {
            return nil
        }
    }
}
#endif

// MARK: - Rule-based fallback for common learner mistakes

@MainActor
enum EnglishRules {
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
    ]
    static let regularVerbs: Set<String> = [
        "walk", "play", "watch", "visit", "call", "cook", "study", "live", "work", "like", "love", "want", "talk",
        "open", "close", "start", "finish", "help", "clean", "use", "need", "ask", "reach", "arrive", "travel",
        "wait", "stay", "listen", "learn", "try", "cry", "carry", "move", "dance", "wash", "fix", "miss", "enjoy",
        "plan", "stop", "shop", "jump", "laugh", "look", "order", "pick", "join", "return", "change", "decide",
        "prepare", "practice", "practise", "remember", "share", "show", "smile", "agree", "believe", "hope",
    ]
    static var baseVerbs: Set<String> { regularVerbs.union(irregularPast.keys) }
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
                                          "little", "large", "young", "beautiful", "best", "other", "more", "different"]
    static let placeNouns: Set<String> = ["office", "market", "station", "airport", "bank", "gym", "park", "cinema",
                                          "mall", "doctor", "shop", "temple", "beach", "hotel", "library", "museum"]
    static let thirdSingular: Set<String> = ["he", "she", "it"]
    static let plainSubjects: Set<String> = ["i", "you", "we", "they"]

    static func sForm(_ v: String) -> String {
        switch v {
        case "go": return "goes"; case "do": return "does"; case "have": return "has"
        default:
            if ["s", "x", "z"].contains(String(v.suffix(1))) || v.hasSuffix("ch") || v.hasSuffix("sh") { return v + "es" }
            if v.hasSuffix("y"), let c = v.dropLast().last, !"aeiou".contains(c) { return v.dropLast() + "ies" }
            return v + "s"
        }
    }
    static func past(_ v: String) -> String {
        if let p = irregularPast[v] { return p }
        if ["stop", "plan", "shop", "jog"].contains(v) { return v + String(v.last!) + "ed" }
        if v.hasSuffix("e") { return v + "d" }
        if v.hasSuffix("y"), let c = v.dropLast().last, !"aeiou".contains(c) { return v.dropLast() + "ied" }
        return v + "ed"
    }
    static func plural(_ n: String) -> String {
        let irregular = ["child": "children", "man": "men", "woman": "women", "person": "people",
                         "foot": "feet", "tooth": "teeth", "mouse": "mice"]
        if let p = irregular[n] { return p }
        if ["s", "x", "z"].contains(String(n.suffix(1))) || n.hasSuffix("ch") || n.hasSuffix("sh") { return n + "es" }
        if n.hasSuffix("y"), let c = n.dropLast().last, !"aeiou".contains(c) { return n.dropLast() + "ies" }
        return n + "s"
    }
    static func keepCase(_ like: String, _ new: String) -> String {
        guard let f = like.first, f.isUppercase, like != "I" else { return new }
        return new.prefix(1).uppercased() + new.dropFirst()
    }

    static func tokenize(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:'[A-Za-z]+)?|[^\\sA-Za-z0-9]")
        return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            .map { (s as NSString).substring(with: $0.range) }
    }
    static func join(_ t: [String]) -> String {
        var out = ""
        for tok in t {
            if out.isEmpty || [".", ",", "!", "?", ";", ":", "'"].contains(tok) { out += tok } else { out += " " + tok }
        }
        return out
    }
    static func isWord(_ s: String) -> Bool { s.first?.isLetter ?? false }

    static func correct(_ text: String) -> (String, [String]) {
        var t = tokenize(text)
        var tips: [String] = [], minorTips: [String] = []
        func lc(_ i: Int) -> String { i >= 0 && i < t.count ? t[i].lowercased() : "" }
        func tip(_ s: String) { if !tips.contains(s) { tips.append(s) } }
        func minor(_ s: String) { if !minorTips.contains(s) { minorTips.append(s) } }   // apostrophes/spelling

        // 1. Spoken-text cleanup: apostrophes, "i" → "I", wrong past forms, repeated words
        var i = 0
        while i < t.count {
            let w = lc(i)
            if let a = apostrophes[w] { t[i] = keepCase(t[i], a); minor("Add the apostrophe: '\(a)'.") }
            else if w == "i" { t[i] = "I" }
            else if let p = badPast[w] { t[i] = keepCase(t[i], p); tip("'\(w)' isn't a word — use '\(p)'.") }
            if i > 0, isWord(t[i]), lc(i) == lc(i - 1) { t.remove(at: i); continue }
            i += 1
        }

        // 2. "Me and him is …" → "He and I are …"
        if t.count >= 4, lc(0) == "me", lc(1) == "and", let subj = ["him": "He", "her": "She", "them": "They"][lc(2)] {
            t[0] = subj; t[2] = "I"
            if ["is", "am"].contains(lc(3)) { t[3] = "are" } else if lc(3) == "was" { t[3] = "were" }
            tip("Say '\(subj) and I' as the subject.")
        }

        // 3. "Their is/are" → "There is/are"
        for i in t.indices where lc(i) == "their" && ["is", "are", "was", "were"].contains(lc(i + 1)) {
            t[i] = keepCase(t[i], "there"); tip("Use 'there is' (not 'their').")
        }

        // 4. "am/is/are agree/know/…" → drop the extra 'be'
        let stative: Set<String> = ["agree", "know", "understand", "believe", "want", "need", "like", "love"]
        i = 0
        while i < t.count {
            if ["am", "is", "are"].contains(lc(i)), stative.contains(lc(i + 1)), i > 0 {
                let v = lc(i + 1), be = lc(i)
                t.remove(at: i)
                tip("Say '\(t[i - 1]) \(thirdSingular.contains(lc(i - 1)) ? sForm(v) : v)' — no '\(be)' needed.")
                if thirdSingular.contains(lc(i - 1)) { t[i] = sForm(v) }
                continue
            }
            i += 1
        }

        // 5. Past-time words → past tense after a subject pronoun
        let words = t.map { $0.lowercased() }
        let pastMarker = words.contains("yesterday") || words.contains("ago")
            || zip(words, words.dropFirst()).contains { $0 == "last" && ["night", "week", "month", "year", "time", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "evening", "morning"].contains($1) }
        let lastIdx = words.firstIndex(of: "last")
        let marker = words.contains("yesterday") ? "yesterday"
            : (words.contains("ago") ? "ago" : "last \(lastIdx.map { $0 + 1 < words.count ? words[$0 + 1] : "" } ?? "")")
        let sMap = Dictionary(baseVerbs.map { (sForm($0), $0) }, uniquingKeysWith: { a, _ in a })
        if pastMarker {
            for i in t.indices where thirdSingular.contains(lc(i)) || plainSubjects.contains(lc(i)) {
                let j = i + 1, v = lc(j)
                guard j < t.count else { continue }
                var newV: String?
                if baseVerbs.contains(v) { newV = past(v) }
                else if let b = sMap[v] { newV = past(b) }
                else if ["am", "is"].contains(v) { newV = "was" }
                else if v == "are" { newV = "were" }
                else if ["don't", "doesn't"].contains(v) { newV = "didn't" }
                if let nv = newV, nv != v {
                    t[j] = nv; tip("Use '\(nv)' (past tense) with '\(marker)'.")
                }
            }
        } else {
            // 6. Subject–verb agreement (present)
            for i in t.indices {
                var s = lc(i)
                let j = i + 1, v = lc(j)
                guard j < t.count, !v.isEmpty else { continue }
                if s == "i" && lc(i - 1) == "and" { s = "we" }   // compound subject: "He and I are"
                var nv: String?
                if thirdSingular.contains(s) {
                    switch v {
                    case "have": nv = "has"; case "do": nv = "does"; case "don't": nv = "doesn't"
                    case "are": nv = "is"; case "were": nv = "was"; case "am": nv = "is"
                    default: if regularVerbs.contains(v) || irregularPast[v] != nil { nv = sForm(v) }
                    }
                } else if s == "i" {
                    switch v { case "is", "are": nv = "am"; case "has": nv = "have"; case "does": nv = "do"
                    case "doesn't": nv = "don't"; default: if let b = sMap[v], b != v { nv = b } }
                } else if plainSubjects.contains(s) {
                    switch v { case "is", "am": nv = "are"; case "has": nv = "have"; case "does": nv = "do"
                    case "doesn't": nv = "don't"; case "was": nv = "were"; default: if let b = sMap[v], b != v { nv = b } }
                }
                if let nv, nv != v {
                    t[j] = nv
                    tip("Use '\(t[i]) \(nv)'" + (thirdSingular.contains(s) && !["is", "was"].contains(nv) ? " (he/she/it + -s)." : "."))
                }
            }
        }

        // 7. Plural after numbers ("two apple" → "two apples")
        for i in t.indices where numberWords.contains(lc(i)) {
            var j = i + 1
            if adjectives.contains(lc(j)) { j += 1 }
            let n = lc(j)
            guard j < t.count, isWord(t[j]), n.count > 2, !n.hasSuffix("s"), !["of", "more", "people", "children", "men", "women", "times", "and", "or", "the", "a"].contains(n),
                  !baseVerbs.contains(n) else { continue }
            let p = plural(n)
            t[j] = keepCase(t[j], p); tip("Use the plural '\(p)' after '\(lc(i))'.")
        }

        // 8. Missing article before common places ("go to market" → "go to the market")
        i = 0
        while i < t.count {
            if ["to", "at", "from", "in"].contains(lc(i)), placeNouns.contains(lc(i + 1)) {
                t.insert("the", at: i + 1); tip("Add 'the': '\(lc(i)) the \(lc(i + 2))'.")
                i += 2; continue
            }
            i += 1
        }

        // 9. "everyday" used as an adverb, and common redundancies
        for i in t.indices where lc(i) == "everyday" && (i + 1 >= t.count || !isWord(t[i + 1])) {
            t[i] = "every day"; tip("'Every day' (two words) means daily.")
        }
        let redundant: [(String, String, String)] = [("discuss", "about", "Say 'discuss' without 'about'."),
                                                     ("return", "back", "'Return' already means 'go back'."),
                                                     ("repeat", "again", "'Repeat' already means 'again'."),
                                                     ("revert", "back", "'Revert' already means 'go back'.")]
        i = 0
        while i < t.count {
            if let r = redundant.first(where: { $0.0 == lc(i) && $0.1 == lc(i + 1) }) { t.remove(at: i + 1); tip(r.2) }
            i += 1
        }

        // 10. NSSpellChecker autocorrections for anything else
        var s = join(t)
        let sc = NSSpellChecker.shared
        var orth: NSOrthography?, wc = 0
        let results = sc.check(s, range: NSRange(location: 0, length: (s as NSString).length),
                               types: NSTextCheckingResult.CheckingType.correction.rawValue,
                               options: nil, inSpellDocumentWithTag: 0, orthography: &orth, wordCount: &wc)
        for r in results.reversed() where r.resultType == .correction {
            if let rep = r.replacementString {
                let old = (s as NSString).substring(with: r.range)
                s = (s as NSString).replacingCharacters(in: r.range, with: rep)
                minor("Spelling: '\(old)' → '\(rep)'.")
            }
        }

        // 11. Capital letter + full stop
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        if let l = s.last, !".!?".contains(l) { s += "." }
        return (s, tips + minorTips)
    }
}
