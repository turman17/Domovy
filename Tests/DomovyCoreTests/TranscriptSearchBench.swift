@testable import DomovyCore
import Foundation
import Testing

/// Timing of the transcript index over a synthetic home (`scripts/bighome.sh`), never the real
/// one. Runs only when `DOMOVY_BENCH_HOME` is set:
/// `DOMOVY_BENCH_HOME=$PWD/.bighome swift test -c release -Xswiftc -enable-testing --filter TranscriptSearchBench`
/// The index goes to a temp folder. Prints counts and times only; never a query result's text.
@Suite("Transcript search bench")
struct TranscriptSearchBench {
    static let home = ProcessInfo.processInfo.environment["DOMOVY_BENCH_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    @Test("build, update and query the index", .enabled(if: home != nil))
    func bench() async throws {
        guard let home = Self.home else { return }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-search-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: store) }
        let context = DomovyContext(home: home, isCustomHome: true, executor: Executor(storeRoot: store))
        let searcher = TranscriptSearcher(context: context)
        let clock = ContinuousClock()
        var sessions: [Session] = []
        let listTime = try await clock.measure { sessions = try await searcher.sessions() }
        let byKind = Dictionary(context.adapters.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        var texts: [[String]] = []
        let readTime = try await clock.measure {
            for session in sessions {
                let transcript = (try? await byKind[session.agent]?.transcript(of: session, limit: TranscriptSearchIndex.maxMessages, masking: [])) ?? .empty
                texts.append(transcript.messages.map(SearchSnippet.text(of:)))
            }
        }
        let maskTime = clock.measure {
            let masker = TranscriptMask.TextMasker()
            for session in texts { for text in session { _ = masker.mask(text) } }
        }
        print("bench parts: read \(readTime), mask \(maskTime), \(texts.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } } / 1_000_000) MB of text")
        let index = try searcher.openIndex()
        var summary = TranscriptSearchIndex.Summary()
        let buildTime = try await clock.measure { summary = try await index.update(sessions: sessions, adapters: context.adapters) }
        let updateTime = try await clock.measure { _ = try await index.update(sessions: sessions, adapters: context.adapters) }
        let size = FileSystem.size(of: TranscriptSearchIndex.file(storeRoot: store))
            + FileSystem.size(of: URL(fileURLWithPath: TranscriptSearchIndex.file(storeRoot: store).path + "-wal"))
        print("bench index: \(sessions.count) sessions listed in \(listTime); built in \(buildTime) (\(summary.indexed) read, \(summary.unreadable) unreadable); "
            + "no-change update \(updateTime); \(size / 1_000) KB on disk")
        for query in ["retry", "rate limiting", "\"the billing module\"", "fix log", "zzzznotthere", "a"] {
            var hits: [TranscriptHit] = []
            let time = try await clock.measure { hits = try await index.search(SearchQuery(query), limit: 5_000) }
            print("bench query #\(query.count) chars: \(hits.count) sessions, \(hits.reduce(0) { $0 + $1.matchCount }) messages in \(time)")
        }
    }
}
