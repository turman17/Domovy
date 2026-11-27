import Foundation
import os

/// "Install 'domo' command in PATH", like VS Code's `code`: a symlink to the `domo` inside
/// Domovy.app in a folder on the user's PATH. Domovy only ever creates, replaces or removes its
/// own link (one that points at `…/Contents/Helpers/domo`); any other `domo` is left alone.
public struct DomoCommandLink: Sendable {
    public enum Status: Sendable, Hashable {
        /// Domovy's link, and whether its folder is on the user's PATH.
        case linked(URL, onPath: Bool)
        /// A `domo` Domovy did not put there (Homebrew's, a dev build) is on PATH already.
        case otherOnPath(URL)
        case notInstalled
    }

    /// Where `install` would put the link.
    public struct Target: Sendable, Hashable {
        public let link: URL
        public let onPath: Bool
        /// What to add to the shell profile when the folder is not on PATH yet.
        public let pathAdvice: String?
    }

    public enum LinkError: Error, Sendable {
        case noBundledDomo
        case occupied(URL)

        public var message: String {
            switch self {
            case .noBundledDomo: "This copy of Domovy has no domo inside it, so there is nothing to link."
            case .occupied(let url): "\(url.path) already exists and is not Domovy's link, so Domovy left it alone."
            }
        }
    }

    public let home: URL
    public let isCustomHome: Bool
    /// The folders of the user's login shell PATH.
    public let pathDirectories: [String]
    private let logger = Logger(subsystem: "com.turman.domovy", category: "connect")

    /// - Parameter pathDirectories: the user's PATH; `nil` asks their login shell (never for a custom home).
    public init(home: URL, isCustomHome: Bool, pathDirectories: [String]? = nil) {
        self.home = home.standardizedFileURL
        self.isCustomHome = isCustomHome
        self.pathDirectories = pathDirectories ?? (isCustomHome ? [] : Self.loginShellPath())
    }

    /// Folders Domovy may link into, preferred first. `/usr/local/bin` only when it is writable
    /// without an administrator password; `/opt/homebrew/bin` never, it belongs to Homebrew.
    var candidates: [URL] {
        let local = home.appendingPathComponent(".local/bin", isDirectory: true)
        if isCustomHome { return [local] }
        return [local, URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)]
    }

    public func status() -> Status {
        for directory in candidates {
            let link = directory.appendingPathComponent("domo")
            if Self.isOurs(link) { return .linked(link, onPath: isOnPath(directory)) }
        }
        for directory in pathDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("domo")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return .otherOnPath(candidate) }
        }
        return .notInstalled
    }

    /// Where the link goes: the first candidate on PATH Domovy can write to, else `~/.local/bin`
    /// with advice to add it to PATH.
    public func target() -> Target {
        let fm = FileManager.default
        for directory in candidates where isOnPath(directory) {
            let link = directory.appendingPathComponent("domo")
            let writable = fm.fileExists(atPath: directory.path) ? fm.isWritableFile(atPath: directory.path) : directory.path.hasPrefix(home.path + "/")
            if writable, !Self.isForeign(link) { return Target(link: link, onPath: true, pathAdvice: nil) }
        }
        let link = home.appendingPathComponent(".local/bin/domo")
        return Target(link: link, onPath: false, pathAdvice: "export PATH=\"$HOME/.local/bin:$PATH\"")
    }

    /// Creates (or points again) Domovy's link at `bundled`.
    @discardableResult
    public func install(bundled: URL?) throws -> Target {
        guard let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) else { throw LinkError.noBundledDomo }
        let target = target()
        let fm = FileManager.default
        if Self.isForeign(target.link) { throw LinkError.occupied(target.link) }
        try fm.createDirectory(at: target.link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Self.isOurs(target.link) { try fm.removeItem(at: target.link) }
        try fm.createSymbolicLink(at: target.link, withDestinationURL: bundled.standardizedFileURL)
        logger.info("linked domo")
        return target
    }

    /// Removes Domovy's links. Returns the ones removed; foreign files stay.
    @discardableResult
    public func uninstall() throws -> [URL] {
        var removed: [URL] = []
        for directory in candidates {
            let link = directory.appendingPathComponent("domo")
            guard Self.isOurs(link) else { continue }
            try FileManager.default.removeItem(at: link)
            removed.append(link)
        }
        return removed
    }

    /// The command to make the link by hand, with an administrator password.
    public static func manualCommand(bundled: URL) -> String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf \(ConnectManual.quoted(bundled.path)) /usr/local/bin/domo"
    }

    // MARK: Helpers

    func isOnPath(_ directory: URL) -> Bool {
        let wanted = directory.standardizedFileURL.path
        return pathDirectories.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == wanted }
    }

    /// A symlink Domovy made: it points at `domo` in an app bundle's Helpers folder.
    static func isOurs(_ link: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        return destination.hasSuffix(".app/Contents/Helpers/domo")
    }

    /// Something is at `link` that Domovy did not make (a dangling link of ours still counts as ours).
    static func isForeign(_ link: URL) -> Bool {
        let exists = (try? FileManager.default.attributesOfItem(atPath: link.path)) != nil
        return exists && !isOurs(link)
    }

    /// PATH as the user's login shell sets it. Apps started from Finder get launchd's short PATH.
    static func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__DOMOVY_PATH__"
        // -i reads ~/.zshrc too, where most people extend PATH. stdin is closed, so nothing waits for input.
        guard let result = ExternalTool.output(URL(fileURLWithPath: shell), ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 5),
              let start = result.stdout.range(of: marker),
              let end = result.stdout.range(of: marker, range: start.upperBound..<result.stdout.endIndex) else {
            return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        }
        return result.stdout[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
    }
}
