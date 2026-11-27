import Foundation

/// The adapters, footprint providers and executor for one home folder, built the same way the
/// app and the CLI build them. A custom home (a fixture or `.devhome`) never runs the real agent
/// CLIs, only stubs in `<home>/bin`.
public struct DomovyContext: Sendable {
    public let home: URL
    public let isCustomHome: Bool
    /// `settings.json` under this home's Domovy folder, or what the caller passed.
    public let settings: DomovySettings
    public let adapters: [any AgentAdapter]
    public let executor: Executor

    /// Without `adapters`, the standard ones minus the agents hidden in `settings`.
    public init(home: URL, isCustomHome: Bool, adapters: [any AgentAdapter]? = nil, executor: Executor? = nil,
                settings: DomovySettings? = nil) {
        self.home = home.standardizedFileURL
        self.isCustomHome = isCustomHome
        let settings = settings ?? SettingsStore.settings(storeRoot: Self.storeRoot(home: home))
        self.settings = settings
        self.adapters = adapters ?? Self.standardAdapters(home: home, isCustomHome: isCustomHome, settings: settings)
        self.executor = executor ?? Executor(storeRoot: Self.storeRoot(home: home))
    }

    /// The real home, or `DOMOVY_ROOT` when set (as the app reads it).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> DomovyContext {
        if let root = environment["DOMOVY_ROOT"], !root.isEmpty {
            return DomovyContext(home: URL(fileURLWithPath: root, isDirectory: true), isCustomHome: true)
        }
        return DomovyContext(home: FileManager.default.homeDirectoryForCurrentUser, isCustomHome: false)
    }

    /// Herdr's panes and agents, so a session running in one counts as live. Empty when Herdr
    /// is not running (a custom home only runs a stub from `<home>/bin`).
    public func herdrState() -> HerdrState {
        HerdrClient.at(home: home, isCustomHome: isCustomHome).state() ?? .empty
    }

    /// Domovy's own folder (quarantine, undo log) under a home.
    public static func storeRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Domovy", isDirectory: true)
    }

    /// Every session adapter, in display order, without the agents `settings` hides.
    public static func standardAdapters(home: URL, isCustomHome: Bool, settings: DomovySettings = DomovySettings()) -> [any AgentAdapter] {
        let window = settings.expiringWindowDays
        let all: [any AgentAdapter] = [
            ClaudeCodeAdapter(home: home, expiringWindowDays: window),
            CodexAdapter(home: home, cli: CodexCLI.choice(home: home, isCustomHome: isCustomHome)),
            GeminiAdapter(home: home, expiringWindowDays: window),
            AntigravityAdapter(home: home),
            OpenCodeAdapter(home: home, cli: OpenCodeCLI.choice(home: home, isCustomHome: isCustomHome)),
            CopilotAdapter(home: home),
            CursorAdapter(home: home),
            ZedAdapter(home: home),
            VSCodeChatAdapter(home: home),
            GeminiCodeAssistAdapter(home: home),
            OpenCodeAdapter(home: home, cli: OpenCodeCLI.choice(home: home, isCustomHome: isCustomHome, flavor: .kilo), flavor: .kilo),
            QwenAdapter(home: home),
            KimiAdapter(home: home),
            RooCodeAdapter(home: home),
            CrushAdapter(home: home, cli: CrushCLI.choice(home: home, isCustomHome: isCustomHome)),
            ClineAdapter(home: home, cli: ClineCLI.choice(home: home, isCustomHome: isCustomHome)),
            ContinueAdapter(home: home),
            JSONLSessionAdapter(home: home, flavor: .auggie),
            JSONLSessionAdapter(home: home, flavor: .factoryDroid),
            KiroAdapter(home: home),
            GooseAdapter(home: home),
            GrokAdapter(home: home),
            AmazonQAdapter(home: home),
        ]
        let others = all.filter { !settings.isHidden($0.kind) }
        guard !settings.isHidden(.aider) else { return others }
        // Aider has no index: it looks for its history files in the folders the others know.
        let discovery = AiderDiscovery.standard(home: home, others: others, searchFolders: settings.aiderSearchFolders)
        return others + [AiderAdapter(home: home, discovery: discovery)]
    }

    /// Every disk footprint: the adapters, the measured-only agents and the model stores,
    /// without the hidden agents.
    public var footprintProviders: [any FootprintProvider] {
        Self.footprintProviders(adapters: adapters, home: home, models: ModelStores.at(home: home, isCustomHome: isCustomHome), settings: settings)
    }

    /// The footprints for `adapters` plus the agents measured only and the model stores.
    public static func footprintProviders(adapters: [any AgentAdapter], home: URL, models: ModelStores,
                                          settings: DomovySettings) -> [any FootprintProvider] {
        let extra = FootprintScanner.measuredOnly(home: home) + FootprintScanner.modelStores(models)
        return adapters + extra.filter { !settings.isHidden($0.kind) }
    }
}
