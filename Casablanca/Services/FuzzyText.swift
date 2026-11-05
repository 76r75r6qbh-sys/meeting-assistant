// Casablanca/Services/FuzzyText.swift
import Foundation

/// Fuzzy text comparison for de-duplicating extracted items ("Stuur offerte
/// naar Kim" vs "Stuur de offerte naar Kim.") and matching quotes.
enum FuzzyText {
    /// Similarity at or above which two texts count as the same item.
    static let matchThreshold = 0.85

    /// Case and diacritics folded, every non-letter/non-digit turned into a
    /// space, whitespace collapsed and trimmed.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(character)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// `1 − Levenshtein(a, b) / max(len)` over the normalized texts, in
    /// characters. Two texts that normalize to empty are identical (1.0).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalized(a)), y = Array(normalized(b))
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(x, y)) / Double(longest)
    }

    private static func levenshtein(_ x: [Character], _ y: [Character]) -> Int {
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
