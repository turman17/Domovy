import ArgumentParser
import DomovyCore
import Foundation

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and remove local models (Ollama, LM Studio, Hugging Face).",
        subcommands: [List.self, Remove.self],
        defaultSubcommand: List.self
    )

    /// Every model across the stores at this root, largest first.
    static func all(_ options: RootOptions) async -> [LocalModel] {
        let result = await FootprintScanner.scan(FootprintScanner.modelStores(options.modelStores))
        for failure in result.failures { FileHandle.standardError.write(Data("domo: \(failure)\n".utf8)) }
        return result.footprints.flatMap(\.models).sorted { $0.sizeBytes > $1.sizeBytes }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ls",
            abstract: "List local models with size and date.",
            discussion: "No store records when a model was last used, so the date is what each store knows: Ollama when the model was added, LM Studio the newest file, Hugging Face the newest download."
        )

        @OptionGroup var options: RootOptions

        @Option(name: .long, help: "Only models whose date is older than this (e.g. 60d, 8w).")
        var unused: AgeThreshold?

        func run() async throws {
            var models = await Models.all(options)
            if let unused {
                let days = Int((unused.seconds / 86_400).rounded(.up))
                models = models.filter { $0.isUnused(days: days) }
            }
            guard !models.isEmpty else {
                print(unused == nil ? "No local models found." : "No local models older than \(unused?.text ?? "").")
                return
            }
            let rows = models.map { model in
                [model.id, Format.bytes(model.sizeBytes), model.date.map { "\(model.dateKind.displayName.lowercased()) \(Format.relative($0))" } ?? "-",
                 model.sharedBytes > 0 ? "+\(Format.bytes(model.sharedBytes)) shared" : ""]
            }
            print(Format.table(rows, header: ["ID", "FREES", "DATE", "SHARED"], rightAligned: [1]))
            let total = models.reduce(Int64(0)) { $0 + $1.sizeBytes }
            print("\n\(models.count) \(models.count == 1 ? "model" : "models"), \(Format.bytes(total)). Preview a removal with `domo models rm <id> --dry-run`.")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove local models.",
            discussion: """
            Uses the tool's own command where there is one (`ollama rm`, `hf cache rm`), which deletes \
            for good, then checks the result. Otherwise files move to the Trash (or the quarantine with \
            --to quarantine) and `domo undo` puts them back. Layers and files another model uses stay. \
            Refuses while a model is loaded in Ollama, LM Studio runs, or anything has the files open.
            """
        )

        @OptionGroup var options: RootOptions

        @Argument(help: "Model ids from `domo models` (ollama:qwen3:14b, lmstudio:<publisher>/<model>, hf:<org>/<name>), or a unique name.")
        var ids: [String]

        @Flag(name: .long, help: "Print the plan and change nothing.")
        var dryRun = false

        @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
        var yes = false

        @Option(name: .long, help: "Where moved files go: trash (default) or quarantine.")
        var to: Destination = .trash

        func run() async throws {
            do {
                let all = await Models.all(options)
                let models = try ids.map { try Self.find($0, in: all) }
                let planner = options.cleanupPlanner
                let removal = try await planner.modelRemovalPlan(models, destination: to)
                for (index, plan) in removal.plans.enumerated() {
                    if index > 0 { print("") }
                    print(Format.plan(plan).replacingOccurrences(of: "Plan for session \(plan.sessionID)", with: "Remove \(plan.sessionID)"))
                }
                if !removal.excluded.isEmpty {
                    print("\nKept:")
                    for item in removal.excluded { print("  \(Format.bytes(item.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.url.lastPathComponent): \(item.reason)") }
                }
                print("\n" + removal.summary)
                if dryRun {
                    print("\nDry run: nothing was changed.")
                    return
                }
                guard !removal.isBlocked else { throw CleanupError.inUse(reasons: removal.reasons) }
                if !yes {
                    try confirm("\n\(removal.title.dropLast())\(removal.isPermanent ? " (some of it for good)" : "")? [y/N] ")
                }
                let entries = try await planner.execute(removal, with: options.executor)
                let undoable = entries.contains { $0.isUndoable }
                print("\nDone.\(undoable ? " Undo what moved with `domo undo`." : "")")
                Domo.printLeftovers(entries)
            } catch {
                throw Domo.fail(error)
            }
        }

        /// An exact id, else an exact name, else a unique id suffix match.
        static func find(_ query: String, in models: [LocalModel]) throws -> LocalModel {
            if let exact = models.first(where: { $0.id == query }) { return exact }
            let named = models.filter { $0.name == query || $0.name == OllamaNames.canonical(query) && $0.agent == .ollama }
            guard named.count == 1, let match = named.first else { throw CleanupError.modelNotFound(query) }
            return match
        }
    }
}
