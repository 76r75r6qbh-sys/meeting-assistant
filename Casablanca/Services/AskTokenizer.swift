import Foundation

/// Pure tokenizer for the cross-meeting "Ask" BM25 index.
///
/// Pipeline: strip `[mm:ss]` / `[h:mm:ss]` labels → fold (diacritics, case,
/// width) → split on every non-letter/digit → drop 1-character tokens unless
/// they are digits → drop nl/en stopwords. No stemming. Order and duplicates
/// are preserved because BM25 needs term frequency.
///
/// Folding is meant to match `normalize()` in `tools/eval/casaeval.py`
/// (NFKD + drop combining marks + casefold) for Dutch/English text.
enum AskTokenizer {

    static func tokens(_ text: String) -> [String] {
        let withoutLabels = timestampLabel.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
        let folded = fold(withoutLabels)
        var result: [String] = []
        for piece in folded.components(separatedBy: separators) where !piece.isEmpty {
            if piece.count == 1 && !piece.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                continue
            }
            if stopwords.contains(piece) { continue }
            result.append(piece)
        }
        return result
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    static let stopwords: Set<String> = [
        // nl
        "de", "het", "een", "en", "van", "naar", "op", "te", "in", "is", "dat", "die", "er",
        "we", "ik", "je", "jij", "hij", "zij", "ze", "wat", "wie", "hoe", "met", "voor", "aan",
        "om", "ook", "maar", "niet", "wel", "nog", "dan", "als", "bij", "of",
        // en
        "the", "a", "an", "and", "or", "to", "on", "for", "are", "was", "be", "it", "that",
        "this", "with", "what", "who", "how", "did", "do", "i", "you",
    ]

    // MARK: - Private

    /// `[mm:ss]` or `[h:mm:ss]` (also tolerates `[hh:mm:ss]`).
    private static let timestampLabel: NSRegularExpression = {
        // Static pattern; a failure here is a programmer error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\d{1,2}:\d{2}(?::\d{2})?\]"#)
    }()

    private static let separators = CharacterSet.alphanumerics.inverted
}
