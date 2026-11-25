import Foundation

/// A chunk with its BM25 score for one query.
struct ScoredChunk: Equatable, Sendable {
    let chunk: AskChunk
    let score: Double
}

/// In-memory BM25 index over Ask chunks (Lucene BM25 with non-negative IDF).
///
/// Pure value type, `Sendable`, no main-actor requirement: build it on any
/// task and search it from anywhere. The indexed text of a chunk is its
/// meeting title, a newline and the chunk text, so a query that matches only
/// the title still retrieves that meeting's chunks. Tokens come from
/// ``AskTokenizer/tokens(_:)``, the same tokenizer used for queries.
///
/// `N`, document frequencies and the average document length are computed
/// over the whole index; `allowedMeetings` only restricts which results are
/// returned, never the statistics.
struct BM25Index: Sendable {
    static let k1 = 1.2
    static let b = 0.75

    private struct Posting: Sendable {
        let doc: Int
        let tf: Int
    }

    private let chunks: [AskChunk]
    private let docLengths: [Int]
    private let postings: [String: [Posting]]
    private let averageDocLength: Double

    init(chunks: [AskChunk], titles: [UUID: String]) {
        var lengths: [Int] = []
        lengths.reserveCapacity(chunks.count)
        var postings: [String: [Posting]] = [:]

        for (doc, chunk) in chunks.enumerated() {
            let text = (titles[chunk.meetingID] ?? "") + "\n" + chunk.text
            let tokens = AskTokenizer.tokens(text)
            lengths.append(tokens.count)

            var frequencies: [String: Int] = [:]
            var order: [String] = []
            for token in tokens {
                if frequencies[token] == nil { order.append(token) }
                frequencies[token, default: 0] += 1
            }
            for term in order {
                postings[term, default: []].append(Posting(doc: doc, tf: frequencies[term] ?? 0))
            }
        }

        self.chunks = chunks
        self.docLengths = lengths
        self.postings = postings
        let total = lengths.reduce(0, +)
        self.averageDocLength = chunks.isEmpty ? 0 : Double(total) / Double(chunks.count)
    }

    /// Number of indexed chunks.
    var count: Int { chunks.count }

    /// Chunks scoring above zero for `query`, restricted to `allowedMeetings`
    /// (`nil` = all meetings), sorted by score descending then chunk id
    /// ascending, at most `limit` results. Repeated query terms count once.
    func search(_ query: String, allowedMeetings: Set<UUID>?, limit: Int) -> [ScoredChunk] {
        guard limit > 0, !chunks.isEmpty, averageDocLength > 0 else { return [] }

        var seen: Set<String> = []
        let terms = AskTokenizer.tokens(query).filter { seen.insert($0).inserted }
        guard !terms.isEmpty else { return [] }

        let n = Double(chunks.count)
        let k1 = Self.k1
        let b = Self.b
        var scores: [Int: Double] = [:]

        for term in terms {
            guard let list = postings[term], !list.isEmpty else { continue }
            let df = Double(list.count)
            let idf = log(1 + (n - df + 0.5) / (df + 0.5))
            for posting in list {
                if let allowedMeetings, !allowedMeetings.contains(chunks[posting.doc].meetingID) { continue }
                let tf = Double(posting.tf)
                let dl = Double(docLengths[posting.doc])
                let norm = tf + k1 * (1 - b + b * dl / averageDocLength)
                scores[posting.doc, default: 0] += idf * tf * (k1 + 1) / norm
            }
        }

        // Final tie-break on index position keeps the order total even if two
        // chunks were given the same id.
        let ranked = scores
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let lhsID = chunks[lhs.key].id, rhsID = chunks[rhs.key].id
                if lhsID != rhsID { return lhsID < rhsID }
                return lhs.key < rhs.key
            }
        return ranked.prefix(limit).map { ScoredChunk(chunk: chunks[$0.key], score: $0.value) }
    }
}
