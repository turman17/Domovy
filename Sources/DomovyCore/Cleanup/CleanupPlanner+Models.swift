import Foundation

/// Local model cleanups (PLAN.md section 4 B): orphaned Ollama blobs, detached Hugging Face
/// revisions, and removing whole models. The tool's own command is preferred (`ollama rm`,
/// `hf cache rm`, `hf cache prune`) and its result verified; the executor keeps a clone of
/// every file it removes, so undo works. Without the command, files move to the Trash or the
/// quarantine, and a blob or shared file another model uses never moves.
extension CleanupPlanner {
    /// The Ollama app and its server (`ollama serve`) and runners. Assumed: process name
    /// `ollama` for the server and CLI, `Ollama` for the menu bar app (not seen running yet).
    static let ollamaMatcher = ProcessMatcher(
        appName: "Ollama", names: ["ollama"],
        quitAdvice: "Quit Ollama first (menu bar icon, Quit Ollama); its server keeps model files open."
    )

    /// LM Studio and its helpers. Assumed from the app name; not verified on an install yet.
    static let lmStudioMatcher = ProcessMatcher(
        appName: "LM Studio", names: ["lm studio"], prefixes: ["lm studio helper"],
        quitAdvice: "Quit LM Studio first; it may have the model loaded."
    )

    /// Said of every tool command that deletes for good: what undo can do, and when the space
    /// comes back.
    static let keptCopyRemark = "Domovy keeps a clone of the files in its quarantine first, so undo can put them back. The disk space comes back when you purge that copy."

    func requireStores(_ id: CleanupID) throws -> ModelStores {
        guard let models else { throw CleanupError.notFound(id) }
        return models
    }

    // MARK: Ollama orphaned blobs

    func ollamaOrphansPlan(destination: Destination) async throws -> CleanupPlan {
        let store = OllamaStore(models: try requireStores(.ollamaOrphanBlobs).ollamaModels)
        let scan = store.scan()
        guard scan.isReliable else {
            throw CleanupError.unknownLayout("Some Ollama manifests are in a format Domovy does not know, so it cannot tell which blobs are unused.")
        }
        let orphans = scan.orphans
        guard !orphans.isEmpty else { throw CleanupError.notFound(.ollamaOrphanBlobs) }
        var items: [(url: URL, note: String)] = []
        var excluded: [CleanupExclusion] = []
        for blob in orphans {
            let age = now().timeIntervalSince(FileSystem.modificationDate(of: blob) ?? now())
            if age < OllamaStore.blobGracePeriod {
                excluded.append(CleanupExclusion(url: blob, sizeBytes: DiskUsage.measure(blob).allocated,
                                                 reason: "Written in the last hour; it may belong to a download in progress."))
            } else {
                items.append((blob, blob.lastPathComponent.contains("-partial") ? "Unfinished download" : "Used by no model"))
            }
        }
        // Only the open-file check blocks: the server may run, but not with these files open.
        return await movePlan(
            .ollamaOrphanBlobs, items: items, matchers: [],
            remarks: ["No manifest references these blobs, so no model needs them. Ollama itself removes such blobs when its server starts, unless OLLAMA_NOPRUNE is set."],
            excluded: excluded, hasConsequences: false, destination: destination
        )
    }

    // MARK: Hugging Face detached revisions

    func detachedRevisionsPlan(destination: Destination) async throws -> CleanupPlan {
        let hub = try requireStores(.huggingFaceDetached).huggingFaceHub
        let scan = HuggingFaceCache(hub: hub).scan()
        let parts = scan.repos.map { ($0, HuggingFaceCache.detachedParts(of: $0, scan: scan, now: now())) }
        let excluded = parts.flatMap { repo, part in
            part.recent.map { CleanupExclusion(url: $0, sizeBytes: DiskUsage.measure($0).allocated, reason: "New or unfinished in \(repo.name); a download may be running.") }
        }
        let all = parts.flatMap { $0.1.all }
        guard !all.isEmpty else { throw CleanupError.notFound(.huggingFaceDetached) }
        let snapshots = parts.flatMap { $0.1.snapshots }.filter { $0.deletingLastPathComponent().lastPathComponent == "snapshots" }
        let remark = "Revisions no branch or tag points at. Files a current revision uses stay, so every other snapshot keeps working."

        if let cli = HuggingFaceCLI.resolve(huggingFaceCLI, hub: hub) {
            let check = await openFileCheck(all)
            let size = DiskUsage.measure(all).allocated
            let command = PlannedCommand(
                executable: cli.executable, arguments: ["cache", "prune", "--yes"], environment: HuggingFaceCLI.environment(hub),
                note: "Runs hf cache prune, then checks the detached revisions are gone.",
                copiesBeforeRun: all, verifications: [.filesGone(snapshots, what: "detached revisions")], sizeBytes: size, isPermanent: true
            )
            let plan = Plan(
                agent: .huggingFace, sessionID: CleanupID.huggingFaceDetached.rawValue, action: .delete, destination: nil,
                moves: [], indexEdits: [], commands: [command], remarks: [remark, Self.keptCopyRemark],
                liveCheck: LiveCheckResult(isLive: !check.reasons.isEmpty, reasons: check.reasons, checkedSignals: ["open file handles"], openHandles: check.status),
                scope: self.scope
            )
            return CleanupPlan(cleanup: .huggingFaceDetached, plan: plan, excluded: excluded, hasConsequences: false)
        }
        let items = parts.flatMap { repo, part in
            part.snapshots.map { ($0, "Detached revision of \(repo.name)") }
                + part.blobs.map { ($0, "Used only by detached revisions of \(repo.name)") }
                + part.storeFiles.map { ($0, "Shared-store file only those revisions use") }
        }
        return await movePlan(.huggingFaceDetached, items: items, matchers: [], remarks: [remark], excluded: excluded,
                              hasConsequences: false, destination: destination)
    }

    // MARK: Removing models

    /// One plan per tool for `models`. Each is looked up again in its store, so the plan
    /// reflects the disk now, not the last scan.
    public func modelRemovalPlan(_ models: [LocalModel], destination: Destination = .trash) async throws -> ModelRemovalPlan {
        guard let stores = self.models, !models.isEmpty else { throw CleanupError.modelNotFound(models.first?.name ?? "") }
        var plans: [Plan] = []
        var excluded: [CleanupExclusion] = []
        let ollama = models.filter { $0.agent == .ollama }
        if !ollama.isEmpty {
            let result = try await ollamaRemoval(ollama.map(\.name), stores: stores, destination: destination)
            plans.append(result.plan)
            excluded += result.excluded
        }
        let lmStudio = models.filter { $0.agent == .lmStudio }
        if !lmStudio.isEmpty {
            plans.append(try await lmStudioRemoval(lmStudio.map(\.name), stores: stores, destination: destination))
        }
        let hf = models.filter { $0.agent == .huggingFace }
        if !hf.isEmpty {
            let result = try await huggingFaceRemoval(hf.map(\.name), hub: stores.huggingFaceHub, destination: destination)
            plans.append(result.plan)
            excluded += result.excluded
        }
        return ModelRemovalPlan(models: models, plans: plans, excluded: excluded)
    }

    /// Checks again right before running: models loaded since, apps started, files opened.
    public func execute(_ removal: ModelRemovalPlan, with executor: Executor) async throws -> [UndoEntry] {
        guard removal.canExecute else {
            throw removal.isBlocked ? CleanupError.inUse(reasons: removal.reasons) : ExecutorError.nothingToDo
        }
        var reasons: [String] = []
        if let stores = models, let cli = OllamaCLI.resolve(ollamaCLI),
           removal.plans.contains(where: { $0.agent == .ollama && !$0.commands.isEmpty }) {
            let names = removal.models.filter { $0.agent == .ollama }.map(\.name)
            reasons += loadedReasons(names, loaded: cli.loadedModels(storeEnvironment: ["OLLAMA_MODELS": stores.ollamaModels.path]) ?? [])
        }
        let urls = removal.plans.flatMap(\.moves).map(\.source) + removal.plans.flatMap(\.commands).flatMap(\.verifications).flatMap(\.urls)
        let check = await openFileCheck(urls)
        reasons += check.reasons
        guard reasons.isEmpty else { throw CleanupError.inUse(reasons: reasons) }
        return try executor.execute(removal.plans)
    }

    private func loadedReasons(_ names: [String], loaded: [String]) -> [String] {
        let running = Set(loaded.map(OllamaStore.canonical))
        return names.filter { running.contains(OllamaStore.canonical($0)) }.map {
            "\($0) is loaded in Ollama right now. Stop it with ollama stop \($0), then try again."
        }
    }

    /// `ollama rm` while the server answers and surely serves the scanned store; otherwise the
    /// manifests and the blobs only the selected models use move, and blobs other models share stay.
    private func ollamaRemoval(_ names: [String], stores: ModelStores, destination: Destination) async throws -> (plan: Plan, excluded: [CleanupExclusion]) {
        let store = OllamaStore(models: stores.ollamaModels)
        let scan = store.scan()
        let manifests = try names.map { name in
            guard let manifest = scan.manifest(named: name) else { throw CleanupError.modelNotFound(name) }
            return manifest
        }
        let selected = Set(manifests.map(\.name))
        let users = scan.users
        // Each freed blob goes with the last selected model that uses it.
        var freed: [String: [URL]] = [:]
        var shared: Set<String> = []
        for (index, manifest) in manifests.enumerated() {
            for blob in Set(manifest.blobNames) {
                let using = users[blob] ?? []
                guard using.isSubset(of: selected) else { shared.insert(blob); continue }
                let last = manifests.lastIndex { $0.blobNames.contains(blob) }
                if last == index { freed[manifest.name, default: []].append(store.blobs.appendingPathComponent(blob)) }
            }
        }
        let sharedURLs = shared.sorted().map { store.blobs.appendingPathComponent($0) }.filter { FileSystem.exists($0) }
        let excluded = sharedURLs.map { url in
            let others = (users[url.lastPathComponent] ?? []).subtracting(selected).sorted()
            return CleanupExclusion(url: url, sizeBytes: DiskUsage.measure(url).allocated, reason: "Shared with \(others.joined(separator: ", ")); stays.")
        }
        var remarks: [String] = []
        if !sharedURLs.isEmpty {
            let n = sharedURLs.count
            remarks.append("\(n) \(n == 1 ? "layer" : "layers") (\(CleanupPlan.bytes(DiskUsage.measure(sharedURLs).allocated))) \(n == 1 ? "is" : "are") shared with other models and \(n == 1 ? "stays" : "stay").")
        }
        let label = manifests.map(\.name).joined(separator: ", ")
        let environment = ["OLLAMA_MODELS": store.models.path]

        let serverStore = servesScannedStore(stores)
        if serverStore, let cli = OllamaCLI.resolve(ollamaCLI), let loaded = cli.loadedModels(storeEnvironment: environment) {
            let commands = manifests.map { manifest in
                let blobs = freed[manifest.name] ?? []
                return PlannedCommand(
                    executable: cli.executable, arguments: ["rm", manifest.name], environment: environment,
                    note: "Runs ollama rm \(manifest.name).",
                    copiesBeforeRun: [manifest.url] + blobs,
                    verifications: [.fileGone(manifest.url), .filesGone(blobs, what: "layers of \(manifest.name)")],
                    sizeBytes: DiskUsage.measure([manifest.url] + blobs).allocated, isPermanent: true
                )
            }
            let pulls = manifests.map { "ollama pull \($0.name)" }.joined(separator: ", ")
            remarks.insert(contentsOf: [Self.keptCopyRemark, "Or download it again with \(pulls)."], at: 0)
            // A loaded model shows in `ollama ps`, and its runner holds the weights open.
            let check = await openFileCheck(manifests.map(\.url) + freed.values.flatMap { $0 })
            let reasons = loadedReasons(manifests.map(\.name), loaded: loaded) + check.reasons
            let plan = Plan(
                agent: .ollama, sessionID: label, action: .delete, destination: nil, moves: [], indexEdits: [],
                commands: commands, remarks: remarks,
                liveCheck: LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["ollama ps", "open file handles"], openHandles: check.status),
                scope: self.scope
            )
            return (plan, excluded)
        }

        // No CLI, or the server is down: move the files, and only with a store Domovy fully understands.
        let unknown = scan.isReliable ? [] : ["Some Ollama manifests are in a format Domovy does not know, so it cannot tell which blobs other models share. Start Ollama and Domovy uses ollama rm instead."]
        let items = manifests.flatMap { manifest in
            [(manifest.url, "Manifest of \(manifest.name)")] + (freed[manifest.name] ?? []).map { ($0, "Layer only \(manifest.name) uses") }
        }
        let why = serverStore
            ? "Ollama's server is not answering, so Domovy moves the files itself."
            : "Ollama's server may use another models folder than the one Domovy scanned (OLLAMA_MODELS is set here or in launchctl, or the store is not ~/.ollama/models), so ollama rm could remove the wrong copy. Domovy moves the files itself."
        remarks.insert("\(why) You can undo this while they are in \(destination.displayName).", at: 0)
        let plan = await fileMovePlan(agent: .ollama, label: label, items: items, matchers: [Self.ollamaMatcher],
                                      remarks: remarks, extraReasons: unknown, destination: destination)
        return (plan, excluded)
    }

    /// `ollama rm` acts on the server's store, which Domovy cannot see. It only matches the scanned
    /// one for sure when that is the home's default and nothing moves it: neither Domovy's
    /// environment nor launchd's (`launchctl setenv OLLAMA_MODELS`, which the Ollama app inherits).
    private func servesScannedStore(_ stores: ModelStores) -> Bool {
        let standard = stores.ollamaHome.appendingPathComponent("models", isDirectory: true).standardizedFileURL
        return stores.ollamaModels.standardizedFileURL.path == standard.path && (environment["OLLAMA_MODELS"] ?? "").isEmpty
            && (launchdEnvironment("OLLAMA_MODELS") ?? "").isEmpty
    }

    private func lmStudioRemoval(_ names: [String], stores: ModelStores, destination: Destination) async throws -> Plan {
        let all = LMStudioFootprint.models(in: stores.lmStudioModels.filter { FileSystem.isDirectory($0) })
        let models = try names.map { name in
            guard let model = all.first(where: { $0.name == name }) else { throw CleanupError.modelNotFound(name) }
            return model
        }
        return await fileMovePlan(
            agent: .lmStudio, label: models.map(\.name).joined(separator: ", "),
            items: models.map { ($0.url, "Model folder of \($0.name)") }, matchers: [Self.lmStudioMatcher],
            remarks: ["LM Studio has no command to remove a model, so Domovy moves the folder. You can undo this while it is in \(destination.displayName)."],
            destination: destination
        )
    }

    /// `hf cache rm` when the installed CLI has it; otherwise the repo folder moves with the
    /// shared-store files no other repo links to. Another repo's files never move.
    private func huggingFaceRemoval(_ names: [String], hub: URL, destination: Destination) async throws -> (plan: Plan, excluded: [CleanupExclusion]) {
        let scan = HuggingFaceCache(hub: hub).scan()
        let repos = try names.map { name in
            guard let repo = scan.repo(named: name) else { throw CleanupError.modelNotFound(name) }
            return repo
        }
        let selectedDirs = repos.map { $0.url.path + "/" }
        func isSelected(_ blobPath: String) -> Bool { selectedDirs.contains { blobPath.hasPrefix($0) } }
        var items: [[(url: URL, note: String)]] = []
        var excluded: [CleanupExclusion] = []
        var claimed = Set<String>()
        for repo in repos {
            var own: [(url: URL, note: String)] = [(repo.url, "Repo folder of \(repo.name)")]
            let locks = hub.appendingPathComponent(".locks/\(repo.url.lastPathComponent)", isDirectory: true)
            if FileSystem.exists(locks) { own.append((locks, "Download locks of \(repo.name)")) }
            for blob in repo.blobs {
                guard let target = scan.xetTarget(of: blob), !claimed.contains(target.path) else { continue }
                let links = scan.xetLinks[target.path] ?? []
                if links.allSatisfy(isSelected) {
                    claimed.insert(target.path)
                    own += ([target] + HuggingFaceCache.companions(of: target)).map { ($0, "Shared-store file only \(repo.name) uses") }
                } else {
                    claimed.insert(target.path)
                    excluded.append(CleanupExclusion(url: target, sizeBytes: DiskUsage.measure(target).allocated, reason: "Another repo uses it; stays."))
                }
            }
            items.append(own)
        }
        let label = repos.map(\.name).joined(separator: ", ")

        if let cli = HuggingFaceCLI.resolve(huggingFaceCLI, hub: hub) {
            let all = items.flatMap { $0.map(\.url) }
            let check = await openFileCheck(all)
            let commands = zip(repos, items).map { repo, own in
                PlannedCommand(
                    executable: cli.executable, arguments: ["cache", "rm", repo.cliArgument, "--yes"], environment: HuggingFaceCLI.environment(hub),
                    note: "Runs hf cache rm \(repo.cliArgument).",
                    copiesBeforeRun: own.map(\.url),
                    verifications: [.fileGone(repo.url), .filesGone(Array(own.dropFirst().map(\.url)), what: "files of \(repo.name)")],
                    sizeBytes: DiskUsage.measure(own.map(\.url)).allocated, isPermanent: true
                )
            }
            let plan = Plan(
                agent: .huggingFace, sessionID: label, action: .delete, destination: nil, moves: [], indexEdits: [], commands: commands,
                remarks: [Self.keptCopyRemark, "Or let it download again the next time code asks for it."],
                liveCheck: LiveCheckResult(isLive: !check.reasons.isEmpty, reasons: check.reasons, checkedSignals: ["open file handles"], openHandles: check.status),
                scope: self.scope
            )
            return (plan, excluded)
        }
        let plan = await fileMovePlan(
            agent: .huggingFace, label: label, items: items.flatMap { $0 }, matchers: [],
            remarks: ["The hf CLI is not installed, so Domovy moves the files itself. You can undo this while they are in \(destination.displayName).",
                      "Files other repos use stay, so their snapshots keep working."],
            destination: destination
        )
        return (plan, excluded)
    }
}
