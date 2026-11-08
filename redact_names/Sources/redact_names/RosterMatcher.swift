import Foundation

/// Finds OCR lines that contain a roster name, tolerating small OCR/handwriting errors.
struct RosterMatcher {
    /// Every word of 3+ letters from every roster name, lowercased.
    let words: [String]
    /// Roster words in their original spelling, handed to Vision as `customWords`.
    let customWords: [String]
    let threshold: Double

    init(names: [String], threshold: Double) {
        let parts = names.flatMap { RosterMatcher.words(in: $0) }
        self.customWords = Array(Set(parts.map { $0.original }))
        self.words = Array(Set(parts.map { $0.folded }))
        self.threshold = threshold
    }

    /// One name per line; blank lines ignored.
    static func load(from url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// True if any word on the line is close enough to any roster word.
    /// Matching single words (not just full names) is deliberate: handwriting often
    /// splits or drops a first or last name, and over-redacting is the safe failure.
    func matches(_ line: String) -> Bool {
        RosterMatcher.words(in: line).contains { w in
            words.contains { RosterMatcher.similarity(w.folded, $0) >= threshold }
        }
    }

    // MARK: - Text helpers

    /// Split text into words of 3+ letters. `folded` ignores case and accents.
    static func words(in text: String) -> [(original: String, folded: String)] {
        text.split { !$0.isLetter }
            .filter { $0.count >= 3 }
            .map { (String($0), $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
    }

    /// 1.0 = identical, 0.0 = nothing in common.
    static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        return longest == 0 ? 1 : 1 - Double(levenshtein(a, b)) / Double(longest)
    }

    /// Edit distance: the fewest single-character inserts, deletes or substitutions
    /// needed to turn `a` into `b`. Classic dynamic programming, one row at a time.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)               // distances from "" to each prefix of b
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1,        // delete from a
                                 current[j - 1] + 1,     // insert into a
                                 substitution)
            }
            previous = current
        }
        return previous[b.count]
    }
}
