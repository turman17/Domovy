@testable import DomovyCore
import Foundation
import Testing

/// Timing of the secret scan over a synthetic home (`scripts/bighome.sh`), never the real one.
/// Runs only when `DOMOVY_BENCH_HOME` is set:
/// `DOMOVY_BENCH_HOME=$PWD/.bighome swift test -c release -Xswiftc -enable-testing --filter SecretScanBench`
/// Prints counts, times and a fingerprint of finding positions only; never a value or preview.
@Suite("Secret scan bench")
struct SecretScanBench {
    static let home = ProcessInfo.processInfo.environment["DOMOVY_BENCH_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    @Test("scan every session of each agent", .enabled(if: home != nil))
    func bench() async throws {
        guard let home = Self.home else { return }
        let adapters: [any AgentAdapter] = [
            ClaudeCodeAdapter(home: home),
            CodexAdapter(home: home, cli: .none),
            GeminiAdapter(home: home),
        ]
        for adapter in adapters {
            let sessions = try await adapter.sessions()
            let clock = ContinuousClock()
            var targets: [SecretScanTarget] = []
            let targetTime = try await clock.measure { targets = await SecretScanner.targets(for: sessions, adapters: [adapter]) }
            var report = SecretScanReport()
            let scanTime = try await clock.measure { report = try await SecretScanner().scan(targets) }
            print("bench \(adapter.kind.rawValue): \(sessions.count) sessions, targets \(targetTime), scan \(scanTime), "
                + "\(report.filesScanned) files, \(report.bytesScanned / 1_000_000) MB, \(report.findings.count) findings, "
                + "fingerprint \(Self.fingerprint(report))")
        }
        // The largest Claude Code session alone.
        let claude = ClaudeCodeAdapter(home: home)
        if let big = try await claude.sessions().max(by: { $0.sizeBytes < $1.sizeBytes }) {
            let clock = ContinuousClock()
            var report = SecretScanReport()
            let time = try await clock.measure { report = try await SecretScanner().scan(big, adapter: claude) }
            print("bench largest session: \(report.bytesScanned / 1_000_000) MB in \(time), \(report.findings.count) findings, fingerprint \(Self.fingerprint(report))")
        }
    }

    @Test("the fast matcher agrees with the reference on every line of the bench home", .enabled(if: home != nil))
    func equivalence() throws {
        guard let home = Self.home else { return }
        var lines = 0, differ = 0
        let fast = SecretMatcher(), reference = ReferenceSecretMatcher()
        for folder in [".claude", ".codex", ".gemini"] {
            guard let enumerator = FileManager.default.enumerator(at: home.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where APFSCompression.isRegularFile(url) && !url.lastPathComponent.hasSuffix(".zst") {
                var stream = try LineStream(url: url, maxLineBytes: 4 << 20)
                defer { stream.close() }
                while let line = try stream.next() {
                    lines += 1
                    if fast.matches(in: line.bytes) != reference.matches(in: line.bytes) { differ += 1 }
                }
            }
        }
        print("bench equivalence: \(differ) of \(lines) lines differ")
        #expect(differ == 0)
    }

    /// FNV-1a over positions, rule ids and sessions, order independent of scan order.
    static func fingerprint(_ report: SecretScanReport) -> String {
        let keys = report.findings.map { "\($0.sessionID)|\($0.file.path)|\($0.line)|\($0.byteRange)|\($0.ruleID)|\($0.isRedactable)" }.sorted()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in keys.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
