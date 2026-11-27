import Foundation

/// A small built-in table of list prices, US dollars per million tokens, for estimating what a
/// session cost. Never fetched: Domovy has no network. Prices change, discounts and
/// subscriptions are not known, so every figure from it is labelled an estimate.
///
/// Sources as of `asOf`: Anthropic's published API prices (Claude); OpenAI's and Google's
/// published API prices for the GPT and Gemini models agents commonly record. Cache writes are
/// priced at 1.25x input (Anthropic's 5-minute cache); providers without cache writes record none.
public struct PriceTable: Sendable {
    public struct Price: Hashable, Sendable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheWrite: Double

        init(_ input: Double, _ output: Double, cacheRead: Double, cacheWrite: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite ?? input * 1.25
        }

        func cost(of counts: TokenCounts) -> Double {
            (Double(counts.input) * input + Double(counts.output) * output
                + Double(counts.cacheRead) * cacheRead + Double(counts.cacheWrite) * cacheWrite) / 1_000_000
        }
    }

    public static let asOf = "2026-10-06"

    /// Model id prefixes (normalized, see `normalize`) and their prices. The longest prefix
    /// that ends on a word boundary wins.
    let entries: [(prefix: String, price: Price)]

    public static let standard = PriceTable(entries: [
        // Anthropic
        ("claude-fable-5-1", Price(10, 50, cacheRead: 0.25)),
        ("claude-fable-5", Price(10, 50, cacheRead: 1)),
        ("claude-mythos-5-1", Price(10, 50, cacheRead: 0.25)),
        ("claude-opus-5-5", Price(4, 20, cacheRead: 0.2)),
        ("claude-opus-5", Price(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-8", Price(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-7", Price(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-6", Price(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-5", Price(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-1", Price(15, 75, cacheRead: 1.5)),
        ("claude-opus-4", Price(15, 75, cacheRead: 1.5)),
        ("claude-3-opus", Price(15, 75, cacheRead: 1.5)),
        ("claude-sonnet-5-5", Price(2, 10, cacheRead: 0.2)),
        ("claude-sonnet-5", Price(2, 10, cacheRead: 0.2)),
        ("claude-sonnet-4-6", Price(3, 15, cacheRead: 0.3)),
        ("claude-sonnet-4-5", Price(3, 15, cacheRead: 0.3)),
        ("claude-sonnet-4", Price(3, 15, cacheRead: 0.3)),
        ("claude-3-7-sonnet", Price(3, 15, cacheRead: 0.3)),
        ("claude-3-5-sonnet", Price(3, 15, cacheRead: 0.3)),
        ("claude-haiku-5-5", Price(0.1, 0.5, cacheRead: 0.01)),
        ("claude-haiku-4-5", Price(1, 5, cacheRead: 0.1)),
        ("claude-3-5-haiku", Price(0.8, 4, cacheRead: 0.08)),
        ("claude-3-haiku", Price(0.25, 1.25, cacheRead: 0.03)),
        // OpenAI
        ("gpt-5", Price(1.25, 10, cacheRead: 0.125, cacheWrite: 0)),
        ("gpt-5-codex", Price(1.25, 10, cacheRead: 0.125, cacheWrite: 0)),
        ("gpt-5-mini", Price(0.25, 2, cacheRead: 0.025, cacheWrite: 0)),
        ("gpt-5-nano", Price(0.05, 0.4, cacheRead: 0.005, cacheWrite: 0)),
        ("gpt-5.1", Price(1.25, 10, cacheRead: 0.125, cacheWrite: 0)),
        ("gpt-5.1-codex", Price(1.25, 10, cacheRead: 0.125, cacheWrite: 0)),
        ("gpt-5.1-codex-mini", Price(0.25, 2, cacheRead: 0.025, cacheWrite: 0)),
        ("gpt-4.1", Price(2, 8, cacheRead: 0.5, cacheWrite: 0)),
        ("gpt-4.1-mini", Price(0.4, 1.6, cacheRead: 0.1, cacheWrite: 0)),
        ("gpt-4o", Price(2.5, 10, cacheRead: 1.25, cacheWrite: 0)),
        ("gpt-4o-mini", Price(0.15, 0.6, cacheRead: 0.075, cacheWrite: 0)),
        ("o3", Price(2, 8, cacheRead: 0.5, cacheWrite: 0)),
        ("o4-mini", Price(1.1, 4.4, cacheRead: 0.275, cacheWrite: 0)),
        // Google
        ("gemini-3-pro", Price(2, 12, cacheRead: 0.2, cacheWrite: 0)),
        ("gemini-2.5-pro", Price(1.25, 10, cacheRead: 0.31, cacheWrite: 0)),
        ("gemini-2.5-flash", Price(0.3, 2.5, cacheRead: 0.075, cacheWrite: 0)),
        ("gemini-2.5-flash-lite", Price(0.1, 0.4, cacheRead: 0.025, cacheWrite: 0)),
        ("gemini-2.0-flash", Price(0.1, 0.4, cacheRead: 0.025, cacheWrite: 0)),
    ])

    /// The price of a recorded model id, or `nil` when the table does not know it.
    public func price(for model: String) -> Price? {
        let id = Self.normalize(model)
        guard !id.isEmpty else { return nil }
        var best: (length: Int, price: Price)?
        for entry in entries where id.hasPrefix(entry.prefix) && Self.isBoundary(String(id.dropFirst(entry.prefix.count))) {
            if entry.prefix.count > (best?.length ?? 0) { best = (entry.prefix.count, entry.price) }
        }
        return best?.price
    }

    /// Cost of every priced model; `nil` when none is priced.
    public func estimate(_ usage: TokenUsage) -> CostEstimate? {
        var usd = 0.0
        var priced = false
        var unpriced: Int64 = 0
        for (model, counts) in usage.byModel {
            if let price = price(for: model) {
                usd += price.cost(of: counts)
                priced = true
            } else {
                unpriced += counts.total
            }
        }
        return priced ? CostEstimate(usd: usd, source: .priceTable, unpricedTokens: unpriced) : nil
    }

    /// Lowercased, provider prefixes dropped ("anthropic/", "us.anthropic."), Claude's dotted
    /// versions dashed ("claude-sonnet-4.5" -> "claude-sonnet-4-5"), suffixes like "[1m]" cut.
    static func normalize(_ model: String) -> String {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        for prefix in ["us.anthropic.", "eu.anthropic.", "global.anthropic.", "anthropic."] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count))
        }
        if id.hasPrefix("claude") { id = id.replacingOccurrences(of: ".", with: "-") }
        return id
    }

    /// What may follow a matched prefix: nothing, a date or version stamp, "latest", or a
    /// preview tag. Anything else ("gpt-5.2", "claude-opus-4-9") is another model.
    static func isBoundary(_ rest: String) -> Bool {
        guard let first = rest.first else { return true }
        guard first == "-" || first == "@" || first == ":" else { return false }
        let tail = rest.dropFirst()
        if tail.count >= 6, tail.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "v" || $0 == ":" }) { return true }
        return tail == "latest" || tail.hasPrefix("preview") || tail.hasPrefix("exp") || tail.hasPrefix("thinking")
    }
}
