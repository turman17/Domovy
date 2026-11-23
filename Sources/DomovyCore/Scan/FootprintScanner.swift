import Foundation

/// Measures every agent's footprint concurrently, off the caller's actor. Agents that are
/// not installed are left out; one agent failing does not hide the others.
public enum FootprintScanner {
    public struct Result: Sendable {
        /// In the order of `providers`.
        public let footprints: [Footprint]
        /// User-explainable failures, one per agent that could not be measured.
        public let failures: [String]
    }

    /// The measuring-only providers for agents without a session adapter yet.
    public static func measuredOnly(home: URL) -> [any FootprintProvider] {
        [ClaudeDesktopFootprint(home: home)]
    }

    /// The local model stores: Ollama, LM Studio, Hugging Face.
    public static func modelStores(_ stores: ModelStores) -> [any FootprintProvider] {
        [OllamaFootprint(stores: stores), LMStudioFootprint(stores: stores), HuggingFaceFootprint(stores: stores)]
    }

    public static func scan(_ providers: [any FootprintProvider]) async -> Result {
        let outcomes = await withTaskGroup(of: (Int, Footprint?, String?).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do {
                        return (index, try await provider.footprint(), nil)
                    } catch AdapterError.notInstalled {
                        return (index, nil, nil)
                    } catch {
                        Log.adapter.error("Footprint of \(provider.kind.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
                        return (index, nil, error.localizedDescription)
                    }
                }
            }
            var all: [(Int, Footprint?, String?)] = []
            for await outcome in group { all.append(outcome) }
            return all.sorted { $0.0 < $1.0 }
        }
        return Result(footprints: outcomes.compactMap(\.1), failures: outcomes.compactMap(\.2))
    }
}
