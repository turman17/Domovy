import DomovyCore
import Foundation

/// A throwaway home with OpenCode's data folder copied from `Tests/Fixtures/opencode/<version>/`,
/// `opencode.db` built from `Tests/Fixtures/opencode/sql/`, and the stub CLI at `<base>/bin/opencode`.
final class OpenCodeFixtureHome: Sendable {
    enum IDs {
        static let idle = "ses_5a1b2c3d4ffeQx7Lm2Np9Rt0Vw"
        /// A subagent session of `idle`.
        static let child = "ses_5a1b2c3d5ffeHk3Jm8Pq2Ws6Yz"
        static let landing = "ses_5a1b2c3e1ffeRt8Yu2Io4Pa6Sd"
        /// Archived in OpenCode (`time_archived`).
        static let archived = "ses_4f0e9d8c7ffeBn5Cv1Xz7Lk3Gh"
    }

    let home: URL
    let storeRoot: URL
    let stub: URL
    let flavor: OpenCodeFlavor
    var dataFolder: URL { home.appendingPathComponent(".local/share/\(flavor.folder)", isDirectory: true) }
    var configFolder: URL { home.appendingPathComponent(".config/\(flavor.folder)", isDirectory: true) }
    var database: URL { dataFolder.appendingPathComponent(flavor.databaseName) }

    /// `flavor: .kilo` builds the same rows as `kilo.db` in `.local/share/kilo` with the kilo stub
    /// (Tests/Fixtures/kilo/README.md says why the schema is the same).
    init(version: String = "1.18", flavor: OpenCodeFlavor = .openCode) throws {
        self.flavor = flavor
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-opencode-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        stub = base.appendingPathComponent("bin/\(flavor.executable)")
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("opencode", isDirectory: true)
        try fm.createDirectory(at: dataFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: configFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("\(version)/share/opencode", isDirectory: true), to: dataFolder)
        try fm.copyItem(at: fixtures.appendingPathComponent("\(version)/config/opencode", isDirectory: true), to: configFolder)
        let sql = try String(contentsOf: fixtures.appendingPathComponent("sql/opencode.sql"), encoding: .utf8)
        try CodexFixtureHome.buildDatabase(sql, at: database)
        try fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stubSource = flavor == .kilo
            ? FixtureHome.fixturesRoot.appendingPathComponent("kilo/stub-kilo.sh") : fixtures.appendingPathComponent("stub-opencode.sh")
        try fm.copyItem(at: stubSource, to: stub)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Deterministic: no libproc, no running OpenCode, the stub CLI unless told otherwise.
    func adapter(
        cli: ToolChoice? = nil,
        openHandles: any OpenHandleChecker = UnavailableOpenHandleChecker(),
        running: [RunningProcess]? = [],
        openFiles: [Int32: [String]] = [:]
    ) -> OpenCodeAdapter {
        OpenCodeAdapter(dataFolder: dataFolder, configFolder: configFolder, cli: cli ?? .executable(stub), flavor: flavor,
                        openHandles: openHandles, processes: FixedProcessLister(running, openFiles: openFiles))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func url(_ relative: String) -> URL { dataFolder.appendingPathComponent(relative) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
    func touch(_ marker: String) { FileManager.default.createFile(atPath: url(marker).path, contents: Data()) }

    func stubInvocations() -> [String] {
        ((try? String(contentsOf: url(".stub-\(flavor.executable).log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
