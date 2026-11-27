import Foundation

/// `settings.json` in Domovy's folder: read by the app, `domo` and the MCP server, written by
/// the app's Settings window (0600, replaced atomically). A missing file means defaults.
public struct SettingsStore: Sendable {
    public let storeRoot: URL

    public init(storeRoot: URL) {
        self.storeRoot = storeRoot.standardizedFileURL
    }

    public var file: URL { storeRoot.appendingPathComponent("settings.json") }
    /// The list of Aider search folders older versions read, one path per line.
    var legacyAiderRoots: URL { storeRoot.appendingPathComponent("aider-search-roots.txt") }

    public struct Loaded: Sendable, Equatable {
        public var settings: DomovySettings
        /// Values that were not used, and why.
        public var issues: [SettingsIssue]
        /// The file is there but is not a JSON object; saving keeps a copy of it first.
        public var isUnreadable: Bool
    }

    /// The settings, after a one-time move of `aider-search-roots.txt` into them.
    public func load() -> Loaded {
        migrateIfNeeded()
        return read()
    }

    /// The settings, or defaults when the file cannot be read.
    public static func settings(storeRoot: URL) -> DomovySettings {
        SettingsStore(storeRoot: storeRoot).load().settings
    }

    func read() -> Loaded {
        guard let data = FileManager.default.contents(atPath: file.path) else {
            return Loaded(settings: DomovySettings(), issues: [], isUnreadable: false)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return Loaded(settings: DomovySettings(), issues: [], isUnreadable: false)
        }
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
            let issue = SettingsIssue(key: "", message: "settings.json is not a JSON object, so Domovy uses the defaults. Changing a setting here keeps a copy of the file as settings.json.bak.")
            return Loaded(settings: DomovySettings(), issues: [issue], isUnreadable: true)
        }
        let decoded = DomovySettings.decode(object)
        return Loaded(settings: decoded.settings, issues: decoded.issues, isUnreadable: false)
    }

    /// Writes the changed values and the unknown keys, pretty printed with sorted keys.
    public func save(_ settings: DomovySettings) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        if read().isUnreadable {
            let backup = storeRoot.appendingPathComponent("settings.json.bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: file, to: backup)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(settings.jsonObject))
        data.append(0x0A)
        let staging = storeRoot.appendingPathComponent(".settings.json.\(UUID().uuidString)")
        guard fm.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        guard rename(staging.path, file.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: staging)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Without a settings file, folders from `aider-search-roots.txt` become
    /// `agents.aider.searchFolders`; the old list is renamed `.migrated` so it is read once.
    func migrateIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: file.path),
              let text = try? String(contentsOf: legacyAiderRoots, encoding: .utf8) else { return }
        var settings = DomovySettings()
        settings.aiderSearchFolders = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try save(settings)
            try? fm.moveItem(at: legacyAiderRoots, to: legacyAiderRoots.appendingPathExtension("migrated"))
        } catch {
            Log.adapter.error("Moving the Aider search folders into settings.json failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
