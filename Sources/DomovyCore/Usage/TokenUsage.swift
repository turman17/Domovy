import Foundation

/// Token counts of one model in one session. `input` excludes cached input, so the four
/// numbers add up to what the agent sent and received.
public struct TokenCounts: Codable, Hashable, Sendable {
    /// Input tokens that were not read from a prompt cache.
    public var input: Int64
    /// Output tokens, reasoning included.
    public var output: Int64
    /// Input tokens read from a prompt cache.
    public var cacheRead: Int64
    /// Input tokens written to a prompt cache (Anthropic models; 0 where not recorded).
    public var cacheWrite: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = max(0, input)
        self.output = max(0, output)
        self.cacheRead = max(0, cacheRead)
        self.cacheWrite = max(0, cacheWrite)
    }

    public static let zero = TokenCounts()

    public var total: Int64 { input + output + cacheRead + cacheWrite }
    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
}

/// What a session's transcript records about tokens, per model. Read from the agent's own
/// files; never sent anywhere.
public struct TokenUsage: Codable, Hashable, Sendable {
    /// Counts per model id as the agent recorded it; `""` when it did not record the model.
    public var byModel: [String: TokenCounts]
    /// The cost the agent itself recorded (OpenCode writes one per message), in US dollars.
    public var recordedCostUSD: Double?

    public init(byModel: [String: TokenCounts] = [:], recordedCostUSD: Double? = nil) {
        self.byModel = byModel.filter { !$0.value.isEmpty }
        self.recordedCostUSD = recordedCostUSD
    }

    public var totals: TokenCounts { byModel.values.reduce(.zero, +) }
    public var isEmpty: Bool { totals.isEmpty }
    /// Recorded model ids, largest use first.
    public var models: [String] {
        byModel.filter { !$0.key.isEmpty }.sorted { $0.value.total > $1.value.total }.map(\.key)
    }

    public mutating func add(_ counts: TokenCounts, model: String?) {
        let key = model?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !counts.isEmpty else { return }
        byModel[key, default: .zero] += counts
    }

    /// Adds another session's usage, for totals.
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        var result = lhs
        for (model, counts) in rhs.byModel { result.byModel[model, default: .zero] += counts }
        switch (lhs.recordedCostUSD, rhs.recordedCostUSD) {
        case (nil, nil): result.recordedCostUSD = nil
        case let (a, b): result.recordedCostUSD = (a ?? 0) + (b ?? 0)
        }
        return result
    }

    /// The agent's own cost, else an estimate from `PriceTable`; `nil` when no model is priced.
    public var cost: CostEstimate? {
        if let recorded = recordedCostUSD, recorded > 0 {
            return CostEstimate(usd: recorded, source: .agent, unpricedTokens: 0)
        }
        return PriceTable.standard.estimate(self)
    }
}

/// An estimated cost in US dollars. Always an estimate: list prices, no discounts, no plans.
public struct CostEstimate: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// The agent wrote the cost into its own data.
        case agent
        /// Domovy's built-in price table (`PriceTable.asOf`).
        case priceTable
    }

    public let usd: Double
    public let source: Source
    /// Tokens of models the table does not know, left out of `usd`.
    public let unpricedTokens: Int64

    public var isPartial: Bool { unpricedTokens > 0 }

    /// "≈ $1.24", or "< $0.01".
    public var text: String {
        if usd > 0, usd < 0.01 { return "< $0.01" }
        return "\u{2248} " + usd.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// "$124", "$2.90", "<$0.01" for a table cell, in the user's number format. The cell's
    /// header and tooltip say it is an estimate.
    public var compactText: String {
        let currency = FloatingPointFormatStyle<Double>.Currency(code: "USD")
        if usd > 0, usd < 0.01 { return "<" + 0.01.formatted(currency.precision(.fractionLength(2))) }
        let digits = usd == 0 || usd >= 10 ? 0 : 2
        return usd.formatted(currency.precision(.fractionLength(digits)))
    }

    public var explanation: String {
        switch source {
        case .agent: "Cost as the agent recorded it."
        case .priceTable:
            "Estimate from list prices as of \(PriceTable.asOf), before discounts or subscriptions."
                + (isPartial ? " Some models have no price in Domovy's table and are left out." : "")
        }
    }
}

extension TokenCounts {
    /// "1.2M" style, for tables.
    public static func compact(_ count: Int64) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}
