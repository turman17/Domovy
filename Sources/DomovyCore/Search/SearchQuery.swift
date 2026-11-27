import Foundation

/// What the user typed into a transcript search, split the way the index splits text: words
/// are runs of letters and digits. A bare word matches any word it starts (`auth` finds
/// "authentication"); text in double quotes is a phrase, its words in that order.
/// Queries hold what the user is looking for: never log them.
public struct SearchQuery: Hashable, Sendable {
    public struct Part: Hashable, Sendable {
        /// Lowercased, diacritics folded.
        public let words: [String]
        public let isPhrase: Bool
    }

    public let parts: [Part]

    public init(_ text: String) {
        var parts: [Part] = []
        var rest = Substring(text)
        while let quote = rest.firstIndex(of: "\"") {
            parts += Self.words(in: rest[..<quote]).map { Part(words: [$0], isPhrase: false) }
            let afterQuote = rest.index(after: quote)
            let close = rest[afterQuote...].firstIndex(of: "\"") ?? rest.endIndex
            let words = Self.words(in: rest[afterQuote..<close])
            if words.count == 1 {
                parts.append(Part(words: words, isPhrase: false))
            } else if !words.isEmpty {
                parts.append(Part(words: words, isPhrase: true))
            }
            rest = close < rest.endIndex ? rest[rest.index(after: close)...] : ""
        }
        parts += Self.words(in: rest).map { Part(words: [$0], isPhrase: false) }
        // The same word twice adds nothing.
        var seen: Set<Part> = []
        self.parts = parts.filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { parts.isEmpty }

    /// The FTS5 expression: every part must match. Words hold only letters and digits, so
    /// nothing the user types can reach FTS5's query syntax.
    var ftsExpression: String {
        parts.map(\.ftsExpression).joined(separator: " AND ")
    }

    /// At most this many parts are searched; a longer query keeps its first ones.
    static let maxParts = 8
}

extension SearchQuery.Part {
    /// `"word"*` or `"a phrase"`.
    var ftsExpression: String {
        isPhrase ? "\"\(words.joined(separator: " "))\"" : "\"\(words[0])\"*"
    }
}

extension SearchQuery {

    /// Runs of letters and digits, folded the way the index folds them.
    static func words<S: StringProtocol>(in text: S) -> [String] {
        Self.tokens(in: String(text)).map(\.folded)
    }

    /// Words of `text` with their ranges, for finding matches in displayed text.
    static func tokens(in text: String) -> [(range: Range<String.Index>, folded: String)] {
        var result: [(Range<String.Index>, String)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else if let begin = start {
                result.append((begin..<index, fold(text[begin..<index])))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begin = start { result.append((begin..<text.endIndex, fold(text[begin..<text.endIndex]))) }
        return result
    }

    private static func fold<S: StringProtocol>(_ word: S) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }
}

extension SearchQuery {
    /// Where the query matches in `text`: each word that a bare word starts, and each phrase.
    /// The index also matches other forms of a word ("fixed" finds "fixing"); this does the
    /// same by trimming common English endings, so highlights follow what the index found.
    public func matches(in text: String) -> [Range<String.Index>] {
        let tokens = Self.tokens(in: text)
        guard !tokens.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        for part in parts {
            let stems = part.words.map(Self.stem)
            if part.isPhrase {
                guard tokens.count >= stems.count else { continue }
                for start in 0...(tokens.count - stems.count) {
                    let fits = stems.indices.allSatisfy { tokens[start + $0].folded.hasPrefix(stems[$0]) }
                    if fits { ranges.append(tokens[start].range.lowerBound..<tokens[start + stems.count - 1].range.upperBound) }
                }
            } else {
                for token in tokens where token.folded.hasPrefix(stems[0]) { ranges.append(token.range) }
            }
        }
        return Self.merged(ranges)
    }

    /// Whether every part of the query matches somewhere in `text`.
    public func matchesAll(in text: String) -> Bool {
        let tokens = Self.tokens(in: text).map(\.folded)
        return parts.allSatisfy { part in
            let stems = part.words.map(Self.stem)
            guard part.isPhrase else { return tokens.contains { $0.hasPrefix(stems[0]) } }
            guard tokens.count >= stems.count else { return false }
            return (0...(tokens.count - stems.count)).contains { start in
                stems.indices.allSatisfy { tokens[start + $0].hasPrefix(stems[$0]) }
            }
        }
    }

    /// The word without a common English ending, never shorter than three letters.
    static func stem(_ word: String) -> String {
        for suffix in ["ations", "ation", "ings", "ing", "edly", "ed", "es", "s", "ly"] where word.hasSuffix(suffix) {
            let stem = String(word.dropLast(suffix.count))
            if stem.count >= 3 { return stem }
        }
        return word
    }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
