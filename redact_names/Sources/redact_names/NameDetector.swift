import Foundation
import AppKit              // NSSpellChecker (on-device)
import NaturalLanguage     // NLTagger (on-device)

/// One word (or phrase) flagged as a possible name, and why.
struct NameHit {
    let range: Range<String.Index>
    let reason: String
}

/// How hard to look for names outside the "Name:" label.
enum DetectionMode: String, CaseIterable {
    /// Signals 1 and 2 only: names from the list, and Apple's name tagger. Few false alarms.
    case standard
    /// All four signals. Catches more, but also redacts Capitalized words that are not names.
    case aggressive
}

/// Finds words that look like a person's name, anywhere in a line of text.
/// Several independent signals; any one is enough.
///
///  1. The word is in a big list of first names and surnames (NameData).
///     If the name is also an ordinary English word ("mark", "grace", "baker"),
///     it only counts when Capitalized, so plain sentences survive.
///  2. Apple's NLTagger says it is a personal name (uses sentence context).
///  --- aggressive mode adds: ---
///  3. It is Capitalized and not an English word at all (e.g. "Atticus", or a misread name).
///  4. Two or more Capitalized words in a row ("Scout Finch").
final class NameDetector {
    private let names: Set<Substring>
    private let mode: DetectionMode
    private let speller = NSSpellChecker.shared
    private var englishCache: [String: Bool] = [:]

    /// Printed labels that are Capitalized but are not names.
    private static let labelWords: Set<String> = ["name", "date", "period", "class", "block",
                                                  "hour", "teacher", "score", "grade", "due"]

    init(mode: DetectionMode = .standard) {
        self.mode = mode
        names = Set(NameData.all)
        speller.setLanguage("en")
    }

    private struct Token {
        let text: String            // letters only, "Scout's" -> "Scout"
        let range: Range<String.Index>
        var capitalized: Bool { text.first?.isUppercase ?? false }
        var isLabel: Bool { NameDetector.labelWords.contains(text.lowercased()) }
    }

    /// Possible names in `text`, with the reason each was flagged.
    func hits(in text: String) -> [NameHit] {
        // Split into words of 3+ letters.
        var tokens: [Token] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let base = word.split(separator: "'").first.map(String.init) ?? word
            if base.count >= 3, base.allSatisfy({ $0.isLetter }) {
                tokens.append(Token(text: base, range: range))
            }
        }

        var found: [NameHit] = []

        // Signals 1 and 3: one word at a time.
        for t in tokens {
            let folded = t.text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            let english = isEnglishWord(folded)
            if names.contains(Substring(folded)), t.capitalized || !english {
                found.append(NameHit(range: t.range, reason: "in name list"))
            } else if mode == .aggressive, t.capitalized, !english, !t.isLabel {
                found.append(NameHit(range: t.range, reason: "capitalized, not an English word"))
            }
        }

        // Signal 4 (aggressive): runs of 2+ capitalized words.
        var run: [Token] = []
        func endRun() {
            if run.count >= 2 { run.forEach { found.append(NameHit(range: $0.range, reason: "capitalized run")) } }
            run = []
        }
        for t in tokens where mode == .aggressive {
            // Only words separated by spaces/periods are "in a row" ("Mrs. Dubose"), not "Algebra 1 - Quiz".
            if let prev = run.last, !text[prev.range.upperBound..<t.range.lowerBound].allSatisfy({ $0 == " " || $0 == "." }) {
                endRun()
            }
            if t.capitalized, !t.isLabel { run.append(t) } else { endRun() }
        }
        endRun()

        // Signal 2: Apple's name tagger.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName { found.append(NameHit(range: range, reason: "NLTagger personal name")) }
            return true
        }
        return found
    }

    /// Does the macOS spell checker accept this (lowercase) word?
    private func isEnglishWord(_ lower: String) -> Bool {
        if let known = englishCache[lower] { return known }
        let misspelled = speller.checkSpelling(of: lower, startingAt: 0, language: "en",
                                               wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let result = misspelled.location == NSNotFound
        englishCache[lower] = result
        return result
    }
}
