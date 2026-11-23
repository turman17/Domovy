import Foundation

/// One downloaded model in a local store: an Ollama tag, an LM Studio model folder or a
/// Hugging Face repo. Measured from metadata; model files are never opened.
public struct LocalModel: Identifiable, Hashable, Codable, Sendable {
    /// What `date` stands for. None of the stores records when a model was last used, and
    /// access times are unreliable, so the label says exactly which time it is.
    public enum DateKind: String, Codable, Sendable {
        /// Ollama: when the manifest was written (pull or update).
        case added
        /// LM Studio: the newest file in the model folder.
        case modified
        /// Hugging Face: when the newest revision was downloaded.
        case downloaded

        public var displayName: String {
            switch self {
            case .added: "Added"
            case .modified: "Modified"
            case .downloaded: "Downloaded"
            }
        }
    }

    public let agent: AgentKind
    /// As the tool shows it: `qwen3:14b`, `lmstudio-community/Qwen3-8B-GGUF`, `Qwen/Qwen3-0.6B`.
    public let name: String
    /// The manifest file, model folder or repo folder.
    public let url: URL
    /// Bytes on disk that removing the model frees (what no other model shares).
    public let sizeBytes: Int64
    /// Bytes on disk shared with other models; they stay when this one goes.
    public let sharedBytes: Int64
    public let date: Date?
    public let dateKind: DateKind
    /// Extra facts for the row, e.g. "2 revisions, 1 detached".
    public let detail: String?

    public init(agent: AgentKind, name: String, url: URL, sizeBytes: Int64, sharedBytes: Int64 = 0, date: Date?, dateKind: DateKind, detail: String? = nil) {
        self.agent = agent
        self.name = name
        self.url = url.standardizedFileURL
        self.sizeBytes = sizeBytes
        self.sharedBytes = sharedBytes
        self.date = date
        self.dateKind = dateKind
        self.detail = detail
    }

    /// `ollama:qwen3:14b`, `lmstudio:publisher/model`, `hf:Qwen/Qwen3-0.6B`; `domo models rm` takes it.
    public var id: String { "\(Self.prefix(agent)):\(name)" }

    static func prefix(_ agent: AgentKind) -> String {
        switch agent {
        case .ollama: "ollama"
        case .lmStudio: "lmstudio"
        case .huggingFace: "hf"
        default: agent.rawValue
        }
    }

    /// True when the model's date is older than `days` days. A model without a date is never
    /// called unused.
    public func isUnused(days: Int, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date < now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// The Disk row's note: the consequence, then the detail as a sentence.
    public var note: String {
        guard let detail, !detail.isEmpty else { return consequence }
        return consequence + " " + detail.prefix(1).uppercased() + detail.dropFirst() + "."
    }

    /// What it takes to use the model again, for row notes and the plan sheet.
    public var consequence: String {
        switch agent {
        case .ollama: "Re-download needed to use it again (ollama pull \(name))."
        case .lmStudio: "Re-download needed to use it again (from LM Studio's Discover tab)."
        default: "Re-download needed to use it again; the hub library fetches it on next use."
        }
    }
}

/// Where the local model stores live. A custom home (a fixture or `.devhome`) never reads the
/// developer's environment overrides, so a test can never reach the real stores.
public struct ModelStores: Hashable, Sendable {
    /// `~/.ollama` (keys and history).
    public let ollamaHome: URL
    /// `~/.ollama/models`, or `$OLLAMA_MODELS`.
    public let ollamaModels: URL
    /// `~/.lmstudio/models`, then the older `~/.cache/lm-studio/models`.
    public let lmStudioModels: [URL]
    /// `~/.lmstudio`.
    public let lmStudioHome: URL
    /// `~/.cache/huggingface/hub`, or `$HF_HUB_CACHE`, or `$HF_HOME/hub`.
    public let huggingFaceHub: URL

    public init(ollamaHome: URL, ollamaModels: URL, lmStudioHome: URL, lmStudioModels: [URL], huggingFaceHub: URL) {
        self.ollamaHome = ollamaHome.standardizedFileURL
        self.ollamaModels = ollamaModels.standardizedFileURL
        self.lmStudioHome = lmStudioHome.standardizedFileURL
        self.lmStudioModels = lmStudioModels.map(\.standardizedFileURL)
        self.huggingFaceHub = huggingFaceHub.standardizedFileURL
    }

    public static func at(home: URL, isCustomHome: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> ModelStores {
        let env = isCustomHome ? [:] : environment
        func path(_ key: String) -> URL? {
            env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        }
        let ollama = home.appendingPathComponent(".ollama", isDirectory: true)
        let lmStudio = home.appendingPathComponent(".lmstudio", isDirectory: true)
        let hub = path("HF_HUB_CACHE")
            ?? path("HF_HOME")?.appendingPathComponent("hub", isDirectory: true)
            ?? home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        return ModelStores(
            ollamaHome: ollama,
            ollamaModels: path("OLLAMA_MODELS") ?? ollama.appendingPathComponent("models", isDirectory: true),
            lmStudioHome: lmStudio,
            lmStudioModels: [lmStudio.appendingPathComponent("models", isDirectory: true),
                             home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true)],
            huggingFaceHub: hub
        )
    }
}
