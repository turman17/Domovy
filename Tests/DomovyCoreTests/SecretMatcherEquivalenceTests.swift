@testable import DomovyCore
import Foundation
import Testing

/// The fast matcher and line stream must give exactly what the reference implementations
/// give. Mismatches are reported by position and count only, never by content.
@Suite("Secret matcher equivalence")
struct SecretMatcherEquivalenceTests {
    /// Deterministic generator, so a failure reproduces.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let fragments: [String] = {
        var parts = SecretSamples.allValues + SecretSamples.cases.map(\.text)
        parts += SecretRule.all.flatMap(\.keywords).flatMap { [$0, $0.uppercased(), $0.capitalized] }
        parts += ["password=", "PASSWORD: ", "db_password = ", "api_key\":\"", "API-KEY=", "apikey:", "access_token=", "auth-token: ",
                  "private_key=", "privatekey:", "secret\": \"", "\\\"secret\\\":\\\"", "passwd=", "accessKey=", "my.prod-api_key='",
                  "-----BEGIN ", "-----END RSA PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----", "PRIVATE KEY BLOCK-----",
                  "https://hooks.slack.com/services/", "hooks.slack.com/", "sk-ant-", "sk-proj-", "sk-", "task-", "desk-", "xoxb-", "xoxp-",
                  "ghp_", "github_pat_", "AKIA", "akia", "AIza", "eyJ", ".eyJ", "sk_live_", "rk_test_", "Bearer ",
                  " ", " ", "  ", "=", ":", "\"", "'", "\\", "\\\"", "\t", "\\n", "\n", ",", ".", "-", "_", "/", "{", "}",
                  "é", "ü", "—", "日本", "🙂", "\u{00A0}", "$VAR", "xxxx", "changeme", "process.env.KEY", "0123456789abcdef"]
        return parts
    }()

    static func run(_ random: inout Random) -> String {
        let alphabets = ["abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "0123456789", "_-./+=!@#$%^&*~", "abcdef0123456789"]
        let pool = (0..<Int.random(in: 1...3, using: &random)).map { _ in alphabets.randomElement(using: &random) ?? "" }.joined()
        let chars = Array(pool)
        return String((0..<Int.random(in: 1...160, using: &random)).map { _ in chars.randomElement(using: &random) ?? "a" })
    }

    static func syntheticLines(count: Int, seed: UInt64, pieces: ClosedRange<Int>) -> [Data] {
        var random = Random(state: seed)
        return (0..<count).map { _ in
            var line = ""
            for _ in 0..<Int.random(in: pieces, using: &random) {
                line += Bool.random(using: &random) ? (fragments.randomElement(using: &random) ?? "") : run(&random)
            }
            return Data(line.utf8)
        }
    }

    /// Lines where the two matchers disagree.
    static func mismatches(_ lines: [Data]) -> [Int] {
        let fast = SecretMatcher(), reference = ReferenceSecretMatcher()
        return lines.indices.filter { fast.matches(in: lines[$0]) != reference.matches(in: lines[$0]) }
    }

    @Test("every keyword can be indexed by its first two bytes")
    func keywordLength() {
        #expect(SecretRule.all.allSatisfy { $0.keywords.allSatisfy { $0.utf8.count >= 2 } })
    }

    @Test("same findings as the reference on the samples and random lines")
    func synthetic() {
        var lines = SecretSamples.cases.map { Data($0.text.utf8) } + SecretSamples.cases.map { Data(SecretSamples.claudeLine($0.text).utf8) }
        lines += Self.syntheticLines(count: 6_000, seed: 1, pieces: 1...12)
        lines += Self.syntheticLines(count: 400, seed: 2, pieces: 40...200)
        let bad = Self.mismatches(lines)
        #expect(bad.isEmpty, "\(bad.count) of \(lines.count) lines differ, first at \(bad.prefix(5))")
        // The corpus must actually exercise the rules.
        let found = Set(lines.flatMap { SecretMatcher().matches(in: $0).map(\.ruleID) })
        #expect(found == Set(SecretRule.all.map(\.id)))
    }

    @Test("same findings on long lines with many keywords")
    func longLines() {
        var lines = Self.syntheticLines(count: 12, seed: 3, pieces: 2_000...4_000)
        // Dense keywords, so windows merge, and matches near window ends.
        var dense = ""
        for index in 0..<3_000 { dense += index % 7 == 0 ? "key=\(SecretSamples.password)\(index) " : "api pass token secret " }
        lines.append(Data(dense.utf8))
        lines.append(Data((String(repeating: "a", count: 40) + "password" + String(repeating: "b", count: 40) + "=" + String(repeating: "Zq8vN3x", count: 30)).utf8))
        let bad = Self.mismatches(lines)
        #expect(bad.isEmpty, "\(bad.count) of \(lines.count) long lines differ")
    }

    @Test("same findings over every fixture file")
    func fixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        var lines: [Data] = []
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            guard APFSCompression.isRegularFile(url), let data = try? Data(contentsOf: url) else { continue }
            lines += data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
        }
        #expect(lines.count > 100)
        let bad = Self.mismatches(lines)
        #expect(bad.isEmpty, "\(bad.count) of \(lines.count) fixture lines differ")
    }

    @Test("the line stream gives the same lines as the reference, across chunk and piece boundaries")
    func lineStream() throws {
        var random = Random(state: 4)
        var text = Data()
        for _ in 0..<600 {
            let length = [0, 1, 5, 80, 4_000, 8_191, 8_192, 8_193, 20_000].randomElement(using: &random) ?? 0
            text.append(Data((0..<length).map { _ in UInt8.random(in: 32...126, using: &random) }))
            text.append(UInt8(ascii: "\n"))
        }
        text.append(Data("no newline at the end".utf8))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-lines-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("t.jsonl")
        try text.write(to: url)
        for chunk in [7, 1_000, 8_192, 65_536, LineStream.chunkSize] {
            var fast = try LineStream(url: url, maxLineBytes: 8_192, chunkSize: chunk)
            var reference = try ReferenceLineStream(url: url, maxLineBytes: 8_192, chunkSize: chunk)
            defer { fast.close(); reference.close() }
            var count = 0
            while true {
                let a = try fast.next(), b = try reference.next()
                guard let a, let b else {
                    #expect(a == nil && b == nil, "chunk \(chunk): one stream ended early at \(count)")
                    break
                }
                count += 1
                guard a.number == b.number, a.offset == b.offset, a.bytes == b.bytes, a.isPartial == b.isPartial else {
                    Issue.record("chunk \(chunk): line \(count) differs")
                    break
                }
            }
            #expect(count > 600)
        }
    }
}
