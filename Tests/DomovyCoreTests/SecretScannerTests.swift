@testable import DomovyCore
import Foundation
import Testing

@Suite("Secret scanner")
struct SecretScannerTests {
    private func temporaryFile(_ name: String, _ contents: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func session(_ transcript: URL, id: String = "eeeeeeee-5555-4555-8555-555555555555", agent: AgentKind = .claudeCode) -> Session {
        Session(id: id, agent: agent, title: nil, projectPath: nil, lastActive: Date(), sizeBytes: 0, status: .idle, expiresAt: nil, transcriptURL: transcript)
    }

    private func scan(_ url: URL, maxLineBytes: Int = 4 << 20) async throws -> SecretScanReport {
        try await SecretScanner(maxLineBytes: maxLineBytes).scan([SecretScanTarget(session: session(url), files: [url])])
    }

    @Test("every rule finds its synthetic sample at the exact byte range, inside a JSON string")
    func everyRule() async throws {
        let lines = SecretSamples.cases.map { SecretSamples.claudeLine($0.text) }
        let url = try temporaryFile("t.jsonl", lines.joined(separator: "\n") + "\n")
        let report = try await scan(url)
        let data = try Data(contentsOf: url)

        #expect(report.findings.count == SecretSamples.cases.count)
        for (index, sample) in SecretSamples.cases.enumerated() {
            let found = report.findings.filter { $0.line == index + 1 }
            #expect(found.map(\.ruleID) == [sample.rule], "line \(index + 1)")
            guard let finding = found.first else { continue }
            let bytes = data[Int(finding.byteRange.lowerBound)..<Int(finding.byteRange.upperBound)]
            // In JSON the key's newlines are escaped; compare against the encoded form.
            let expected = sample.value.replacingOccurrences(of: "\n", with: "\\n")
            #expect(String(decoding: bytes, as: UTF8.self) == expected, "\(sample.rule)")
            #expect(finding.isRedactable, "\(sample.rule): \(finding.redaction)")
        }
        let covered = Set(report.findings.map(\.ruleID))
        let expectedRules = Set(SecretRule.all.map(\.id)).subtracting(["private-key-header"])
        #expect(covered == expectedRules)
    }

    @Test("prose, UUIDs, hashes, placeholders and paths are not findings")
    func noFalsePositives() async throws {
        let url = FixtureHome.fixturesRoot.appendingPathComponent("secrets/clean-transcript.jsonl")
        let report = try await scan(url)
        #expect(report.findings.isEmpty, "\(report.findings)")
        #expect(report.filesScanned == 1)
        #expect(report.summary == "No secrets found in 1 session.")
    }

    @Test("previews are masked: public prefix and at most the last four characters")
    func masking() async throws {
        let lines = SecretSamples.cases.map { SecretSamples.claudeLine($0.text) }
        let url = try temporaryFile("t.jsonl", lines.joined(separator: "\n"))
        let report = try await scan(url)
        let previews = Dictionary(uniqueKeysWithValues: report.findings.map { ($0.ruleID, $0.preview) })
        #expect(previews["anthropic-key"] == "sk-ant-\u{2026}a1B2")
        #expect(previews["aws-access-key"] == "AKIA\u{2026}0001")
        #expect(previews["generic-secret"] == "password=\u{2026}")
        #expect(previews["private-key"] == "-----BEGIN PRIVATE KEY-----\u{2026}")
        for finding in report.findings {
            let value = SecretSamples.cases.first { $0.rule == finding.ruleID }?.value ?? ""
            #expect(!finding.preview.contains(value))
            #expect(finding.preview.count < value.count)
        }
    }

    @Test("a finding carries no secret value: description, JSON and every stored field")
    func findingsHoldNoValues() async throws {
        let lines = SecretSamples.cases.map { SecretSamples.claudeLine($0.text) }
        let url = try temporaryFile("t.jsonl", lines.joined(separator: "\n"))
        let report = try await scan(url)
        let encoded = String(decoding: try JSONEncoder().encode(report.findings), as: UTF8.self)
        let described = report.findings.map(String.init(describing:)).joined() + String(reflecting: report.findings) + report.summary
        for value in SecretSamples.allValues {
            let escaped = value.replacingOccurrences(of: "\n", with: "\\n")
            for text in [encoded, described] {
                #expect(!text.contains(value) && !text.contains(escaped))
                #expect(!text.contains(String(value.dropFirst(value.count / 2 - 5).prefix(10))))
            }
        }
    }

    @Test("zstd rollouts are skipped with a reason, binaries quietly, plain text is not redactable")
    func fileKinds() async throws {
        let zst = try temporaryFile("rollout-x.jsonl.zst", "(\u{B5}/\u{FD} not readable")
        let png = try temporaryFile("ig_0001.png", "\u{0}\u{1}PNG \(SecretSamples.aws)")
        let text = try temporaryFile("r1.txt", "output\nAWS key \(SecretSamples.aws)\n")
        let s = session(zst)
        let report = try await SecretScanner().scan([SecretScanTarget(session: s, files: [zst, png, text])])
        #expect(report.skipped.count == 1)
        #expect(report.skipped.first?.reason.contains("zstd") == true)
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.line == 2)
        #expect(report.findings.first?.isRedactable == false)
    }

    @Test("a line longer than the limit is read in pieces; its findings are reported but not redacted")
    func longLines() async throws {
        let filler = String(repeating: "lorem ipsum dolor ", count: 4_000) // ~72 KB
        let line = SecretSamples.claudeLine(filler + " " + SecretSamples.aws + " " + filler + " " + SecretSamples.github)
        let url = try temporaryFile("long.jsonl", "{\"type\":\"summary\"}\n" + line + "\n")
        let report = try await scan(url, maxLineBytes: 16 * 1024)
        #expect(Set(report.findings.map(\.ruleID)) == ["aws-access-key", "github-token"])
        #expect(report.findings.count == 2)
        #expect(report.findings.allSatisfy { $0.line == 2 && !$0.isRedactable })
        let data = try Data(contentsOf: url)
        let aws = try #require(report.findings.first { $0.ruleID == "aws-access-key" })
        #expect(String(decoding: data[Int(aws.byteRange.lowerBound)..<Int(aws.byteRange.upperBound)], as: UTF8.self) == SecretSamples.aws)
    }

    @Test("a secret outside a string value, or on a broken line, is reported as not redactable")
    func notInsideString() async throws {
        let broken = "{\"type\":\"user\",\"text\":\"\(SecretSamples.aws)"
        let bare = "{\"n\":1} \(SecretSamples.stripe)"
        let url = try temporaryFile("t.jsonl", broken + "\n" + bare + "\n")
        let report = try await scan(url)
        #expect(report.findings.count == 2)
        #expect(report.findings.allSatisfy { !$0.isRedactable })
    }

    @Test("JSON string positions: escapes are never split")
    func jsonSpans() {
        let line = Array(("{\"a\":\"x\\n\\" + "u0041" + "yz\",\"b\":1}").utf8)
        // `x` alone, `yz`, and the whole contents are inside; splitting `\n` or the `u0041` escape is not.
        #expect(JSONText.isInsideString(6..<7, of: line))
        #expect(JSONText.isInsideString(15..<17, of: line))
        #expect(JSONText.isInsideString(6..<17, of: line))
        #expect(!JSONText.isInsideString(7..<8, of: line))
        #expect(!JSONText.isInsideString(10..<12, of: line))
        #expect(!JSONText.isInsideString(4..<7, of: line))
        #expect(!JSONText.isInsideString(23..<24, of: line))
    }

    @Test("a cancelled scan stops with CancellationError")
    func cancellation() async throws {
        let lines = (0..<2_000).map { _ in SecretSamples.claudeLine("nothing to see here, just prose") }
        let url = try temporaryFile("t.jsonl", lines.joined(separator: "\n"))
        let targets = (0..<400).map { _ in SecretScanTarget(session: session(url), files: [url]) }
        let task = Task { try await SecretScanner().scan(targets) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("progress is reported once per session")
    func progress() async throws {
        let url = try temporaryFile("t.jsonl", SecretSamples.claudeLine(SecretSamples.cases[0].text))
        let targets = (0..<3).map { _ in SecretScanTarget(session: session(url), files: [url]) }
        let seen = Counter()
        let report = try await SecretScanner().scan(targets) { seen.add($0.sessionsDone) }
        #expect(seen.values == [1, 2, 3])
        #expect(report.findings.count == 3)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    var values: [Int] { lock.withLock { stored } }
    func add(_ value: Int) { lock.withLock { stored.append(value) } }
}
