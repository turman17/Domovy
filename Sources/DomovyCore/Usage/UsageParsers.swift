import Foundation

/// Reads token counts out of the agents' own transcript formats. Whole files are streamed line
/// by line (zstd included); only lines that mention usage are parsed. Only numbers and model
/// ids leave these functions: transcript content is never kept or logged.
enum UsageParsers {
    /// Lines longer than this (a pasted file, a big tool result) cannot hold usage and are skipped.
    static let maxLineBytes = 16 << 20

    /// Calls `body` with each complete line containing one of `needles`, parsed as a JSON object.
    static func eachObject(in url: URL, containing needles: [String], _ body: ([String: Any]) -> Void) throws {
        let patterns = needles.map { Data($0.utf8) }
        var stream = try LineStream(url: url, maxLineBytes: maxLineBytes)
        defer { stream.close() }
        while let line = try stream.next() {
            guard !line.isPartial, patterns.contains(where: { line.bytes.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: line.bytes) as? [String: Any] else { continue }
            body(object)
        }
    }

    static func int(_ value: Any?) -> Int64 {
        switch value {
        case let n as NSNumber: n.int64Value
        case let s as String: Int64(s) ?? 0
        default: 0
        }
    }

    // MARK: Claude Code

    /// Assistant lines carry `message.usage` (`input_tokens`, `output_tokens`,
    /// `cache_creation_input_tokens`, `cache_read_input_tokens`) and `message.model`. One API
    /// response is written as several lines (one per content block) with the same `message.id`;
    /// the last one counts.
    static func claudeCode(_ files: [URL]) throws -> TokenUsage? {
        var byMessage: [String: (model: String?, counts: TokenCounts)] = [:]
        var anonymous: [(model: String?, counts: TokenCounts)] = []
        var sawUsage = false
        for file in files {
            try eachObject(in: file, containing: ["\"usage\""]) { record in
                guard record["type"] as? String == "assistant", let message = record["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { return }
                sawUsage = true
                let model = message["model"] as? String
                guard model != "<synthetic>" else { return }
                let counts = TokenCounts(input: int(usage["input_tokens"]), output: int(usage["output_tokens"]),
                                         cacheRead: int(usage["cache_read_input_tokens"]),
                                         cacheWrite: int(usage["cache_creation_input_tokens"]))
                if let id = (message["id"] as? String) ?? (record["requestId"] as? String) {
                    byMessage[id] = (model, counts)
                } else {
                    anonymous.append((model, counts))
                }
            }
        }
        guard sawUsage else { return nil }
        var usage = TokenUsage()
        for entry in Array(byMessage.values) + anonymous { usage.add(entry.counts, model: entry.model) }
        return usage
    }

    // MARK: Codex

    /// `event_msg` records of type `token_count` carry `info.total_token_usage`, a running total
    /// (`input_tokens` includes `cached_input_tokens`; `output_tokens` includes reasoning).
    /// `turn_context` records name the model; each increase of the total goes to the model of
    /// the turn it happened in.
    static func codex(_ file: URL) throws -> TokenUsage? {
        var usage = TokenUsage()
        var model: String?
        var previous = (input: Int64(0), cached: Int64(0), output: Int64(0))
        var sawUsage = false
        try eachObject(in: file, containing: ["token_count", "turn_context", "\"model\""]) { record in
            let payload = record["payload"] as? [String: Any] ?? record
            let type = record["payload"] != nil ? record["type"] as? String : nil
            if type == "turn_context" || (type == nil && payload["approval_policy"] != nil), let name = payload["model"] as? String {
                model = name
                return
            }
            if type == "session_meta", model == nil, let name = payload["model"] as? String { model = name }
            guard payload["type"] as? String == "token_count",
                  let total = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] else { return }
            sawUsage = true
            let now = (input: int(total["input_tokens"]), cached: int(total["cached_input_tokens"]), output: int(total["output_tokens"]))
            // A total that went down started over (a fork or compaction): count it from zero.
            let base = now.input < previous.input || now.output < previous.output ? (Int64(0), Int64(0), Int64(0)) : previous
            let input = now.input - base.0, cached = min(now.cached - base.1, input)
            usage.add(TokenCounts(input: input - cached, output: now.output - base.2, cacheRead: cached), model: model)
            previous = now
        }
        return sawUsage ? usage : nil
    }

    // MARK: Gemini CLI

    /// Model messages carry `tokens: {input, output, cached, thoughts, tool, total}` (`input`
    /// includes `cached`) and `model`. `$set` lines replace the whole message list; older
    /// versions wrote one JSON object with `messages`.
    static func gemini(_ file: URL) throws -> TokenUsage? {
        var order: [String] = []
        var byID: [String: [String: Any]] = [:]
        func take(_ message: [String: Any], index: Int) {
            let id = message["id"] as? String ?? "m\(index)"
            if byID[id] == nil { order.append(id) }
            byID[id] = message
        }
        var lines = 0
        try eachObject(in: file, containing: ["\"tokens\"", "$set", "\"messages\""]) { object in
            lines += 1
            let update = object["$set"] as? [String: Any]
            if let list = (update?["messages"] ?? object["messages"]) as? [[String: Any]] {
                order = []
                byID = [:]
                for (index, message) in list.enumerated() { take(message, index: index) }
            } else if object["type"] is String, update == nil {
                take(object, index: order.count)
            }
        }
        if lines == 0, FileSystem.size(of: file) < Int64(maxLineBytes),
           let whole = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any],
           let list = whole["messages"] as? [[String: Any]] {
            for (index, message) in list.enumerated() { take(message, index: index) }
        }
        var usage = TokenUsage()
        var sawUsage = false
        for id in order {
            guard let message = byID[id], let tokens = message["tokens"] as? [String: Any] else { continue }
            sawUsage = true
            let cached = int(tokens["cached"])
            usage.add(TokenCounts(input: int(tokens["input"]) - cached, output: int(tokens["output"]) + int(tokens["thoughts"]),
                                  cacheRead: cached), model: message["model"] as? String)
        }
        return sawUsage ? usage : nil
    }

    // MARK: Qwen Code

    /// Assistant records carry Gemini's `usageMetadata` (`promptTokenCount` includes
    /// `cachedContentTokenCount`; `thoughtsTokenCount` is billed as output) and `model`.
    static func qwen(_ file: URL) throws -> TokenUsage? {
        var byRecord: [String: (model: String?, counts: TokenCounts)] = [:]
        var index = 0
        try eachObject(in: file, containing: ["usageMetadata"]) { record in
            guard let meta = record["usageMetadata"] as? [String: Any] else { return }
            index += 1
            let cached = int(meta["cachedContentTokenCount"])
            let counts = TokenCounts(input: int(meta["promptTokenCount"]) - cached,
                                     output: int(meta["candidatesTokenCount"]) + int(meta["thoughtsTokenCount"]), cacheRead: cached)
            byRecord[(record["uuid"] as? String) ?? "r\(index)"] = (record["model"] as? String, counts)
        }
        guard !byRecord.isEmpty else { return nil }
        var usage = TokenUsage()
        for entry in byRecord.values { usage.add(entry.counts, model: entry.model) }
        return usage
    }

    // MARK: Copilot CLI (assumed shape)

    /// `assistant.usage` events (`data.model`, `inputTokens`, `outputTokens`, `cacheReadTokens`,
    /// `cacheWriteTokens`), else the `session.shutdown` summary (`data.modelMetrics`:
    /// `{<model>: {usage: {…same fields}}}`). `inputTokens` is taken to include cache reads, as
    /// OpenAI-style APIs count it. Built from documentation, not a real install.
    static func copilot(_ file: URL) throws -> TokenUsage? {
        var perCall = TokenUsage()
        var shutdown = TokenUsage()
        var sawCalls = false, sawShutdown = false
        func counts(_ fields: [String: Any]) -> TokenCounts {
            let read = int(fields["cacheReadTokens"]), input = int(fields["inputTokens"])
            return TokenCounts(input: input >= read ? input - read : input, output: int(fields["outputTokens"]),
                               cacheRead: read, cacheWrite: int(fields["cacheWriteTokens"]))
        }
        try eachObject(in: file, containing: ["assistant.usage", "modelMetrics"]) { event in
            let data = event["data"] as? [String: Any] ?? [:]
            switch event["type"] as? String {
            case "assistant.usage":
                sawCalls = true
                perCall.add(counts(data), model: data["model"] as? String)
            case "session.shutdown":
                for case let (model, metrics as [String: Any]) in data["modelMetrics"] as? [String: Any] ?? [:] {
                    guard let fields = metrics["usage"] as? [String: Any] else { continue }
                    sawShutdown = true
                    shutdown.add(counts(fields), model: model)
                }
            default:
                break
            }
        }
        if sawCalls { return perCall }
        return sawShutdown ? shutdown : nil
    }

    // MARK: Zed

    /// The thread JSON's `cumulative_token_usage` (`input_tokens`, `output_tokens`,
    /// `cache_creation_input_tokens`, `cache_read_input_tokens`) and `model {provider, model}`.
    static func zed(_ data: Data) -> TokenUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = object["cumulative_token_usage"] as? [String: Any] else { return nil }
        let model = (object["model"] as? [String: Any])?["model"] as? String
        var usage = TokenUsage()
        usage.add(TokenCounts(input: int(total["input_tokens"]), output: int(total["output_tokens"]),
                              cacheRead: int(total["cache_read_input_tokens"]), cacheWrite: int(total["cache_creation_input_tokens"])),
                  model: model)
        return usage
    }

    // MARK: OpenCode, Kilo Code

    /// Assistant `message.data` JSON: `tokens {input, output, reasoning, cache {read, write}}`,
    /// `cost` (US dollars, OpenCode's own figure) and `modelID`. Subagent sessions count toward
    /// their parent.
    static func openCode(database: URL, sessionID: String) -> TokenUsage? {
        guard let reader = SQLiteReader(url: database) else { return nil }
        let sql = """
            WITH RECURSIVE family(id) AS (SELECT ?1 UNION SELECT s.id FROM session s JOIN family f ON s.parent_id = f.id)
            SELECT m.data FROM message m WHERE m.session_id IN (SELECT id FROM family)
            """
        var usage = TokenUsage()
        var cost = 0.0
        var sawUsage = false
        for cells in reader.rows(sql, [sessionID]) {
            guard let text = cells.first ?? nil, text.contains("\"tokens\""),
                  let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let tokens = message["tokens"] as? [String: Any] else { continue }
            sawUsage = true
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            usage.add(TokenCounts(input: int(tokens["input"]), output: int(tokens["output"]) + int(tokens["reasoning"]),
                                  cacheRead: int(cache["read"]), cacheWrite: int(cache["write"])),
                      model: message["modelID"] as? String)
            cost += (message["cost"] as? NSNumber)?.doubleValue ?? 0
        }
        guard sawUsage else { return nil }
        usage.recordedCostUSD = cost > 0 ? cost : nil
        return usage
    }
}
