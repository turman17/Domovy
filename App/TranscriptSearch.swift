import DomovyCore
import Foundation
import Observation
import os
import SwiftUI

/// What the toolbar search looks at in the sessions list.
enum SearchScope: String, CaseIterable, Identifiable {
    case titles = "Titles"
    case transcripts = "Transcripts"

    var id: Self { self }
}

/// Full-text search inside transcripts for the sessions list: keeps Domovy's local index up
/// to date in the background (after the first transcript search, then on every reload), runs
/// queries and keeps the hits of the current one. Queries and snippets are never logged.
@MainActor
@Observable
final class TranscriptSearch {
    var scope: SearchScope = .titles {
        didSet { if scope == .transcripts, oldValue != .transcripts { enable() } }
    }
    /// Settings > Search: off, transcripts are never indexed and only titles are searched.
    var isAllowed = true {
        didSet {
            guard isAllowed != oldValue, !isAllowed else { return }
            scope = .titles
            updateJob?.cancel()
            updateJob = nil
            progress = nil
        }
    }
    /// Sessions looked at of all, while the index is being brought up to date.
    private(set) var progress: TranscriptSearchIndex.Progress?
    /// Why transcript search does not work here, in one plain line.
    private(set) var failure: String?
    /// The query the hits are for, and the hits by session.
    private(set) var query = ""
    private(set) var hits: [String: TranscriptHit] = [:]
    /// Bumped when `hits` change, for views that refilter on it.
    private(set) var revision = 0
    private(set) var isSearching = false

    @ObservationIgnored private let storeRoot: URL
    @ObservationIgnored private var index: TranscriptSearchIndex?
    /// Updates run one after another: a new one waits for the last to stop.
    @ObservationIgnored private var updateJob: Task<Void, Never>?
    @ObservationIgnored private var jobID = 0
    @ObservationIgnored private var searchJob: Task<Void, Never>?
    @ObservationIgnored private var lastSessions: [Session] = []
    @ObservationIgnored private var lastAdapters: [any AgentAdapter] = []
    @ObservationIgnored private var refreshedAtIndexed = 0
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.turman17.Domovy", category: "TranscriptSearch")

    init(storeRoot: URL) {
        self.storeRoot = storeRoot
    }

    /// The index is built once transcript search was used; until then nothing reads transcripts.
    private var isEnabled: Bool {
        guard isAllowed else { return false }
        return index != nil || FileManager.default.fileExists(atPath: TranscriptSearchIndex.file(storeRoot: storeRoot).path)
    }

    private func openIndex() -> TranscriptSearchIndex? {
        if let index { return index }
        do {
            let opened = try TranscriptSearchIndex(storeRoot: storeRoot)
            index = opened
            failure = nil
            return opened
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    // MARK: Index

    /// After a reload: index what changed, drop what is gone.
    func sessionsChanged(_ sessions: [Session], adapters: [any AgentAdapter]) {
        lastSessions = sessions
        lastAdapters = adapters
        guard isEnabled else { return }
        startUpdate()
    }

    /// Empties the index and reads every transcript again.
    func rebuild() {
        guard isAllowed, let index = openIndex() else { return }
        startUpdate(before: { try await index.removeAll() })
    }

    func cancelIndexing() {
        updateJob?.cancel()
    }

    private func enable() {
        guard isAllowed, openIndex() != nil, updateJob == nil else { return }
        startUpdate()
    }

    /// `<store>/Search/transcripts.sqlite`.
    var indexFile: URL { TranscriptSearchIndex.file(storeRoot: storeRoot) }

    /// The index with its journal files, on disk.
    var indexBytes: Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let path = indexFile.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64
            return total + (size ?? 0)
        }
    }

    /// Deletes the index (it holds words from transcripts). The next transcript search, if
    /// allowed, builds it again.
    func clearIndex() {
        updateJob?.cancel()
        updateJob = nil
        searchJob?.cancel()
        progress = nil
        index = nil
        scope = .titles
        hits = [:]
        query = ""
        revision += 1
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: indexFile.path + suffix)
        }
    }

    private func startUpdate(before: (@Sendable () async throws -> Void)? = nil) {
        guard let index = openIndex() else { return }
        let previous = updateJob
        previous?.cancel()
        let sessions = lastSessions
        let adapters = lastAdapters
        refreshedAtIndexed = 0
        let (updates, sink) = AsyncStream.makeStream(of: TranscriptSearchIndex.Progress.self, bufferingPolicy: .bufferingNewest(1))
        let job = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let listening = Task { @MainActor [weak self] in
                for await progress in updates { self?.apply(progress) }
            }
            let started = ContinuousClock.now
            let result: Result<TranscriptSearchIndex.Summary, any Error>
            do {
                try await before?()
                // The index is an actor: this runs off the main actor, and stops between
                // sessions when the job is cancelled.
                result = .success(try await index.update(sessions: sessions, adapters: adapters) { sink.yield($0) })
            } catch {
                result = .failure(error)
            }
            sink.finish()
            await listening.value
            self?.finish(result, started: started)
        }
        updateJob = job
        jobID += 1
        let id = jobID
        Task { [weak self] in
            await job.value
            if self?.jobID == id { self?.updateJob = nil }
        }
    }

    private func finish(_ result: Result<TranscriptSearchIndex.Summary, any Error>, started: ContinuousClock.Instant) {
        progress = nil
        switch result {
        case .success(let summary):
            failure = nil
            // Counts only.
            logger.info("Search index: \(summary.indexed, privacy: .public) read, \(summary.unchanged, privacy: .public) unchanged, \(summary.removed, privacy: .public) removed in \(ContinuousClock.now - started, privacy: .public)")
        case .failure(let error):
            failure = error.localizedDescription
        }
        refresh()
    }

    private func apply(_ next: TranscriptSearchIndex.Progress) {
        if let current = progress, current.total == next.total, current.done > next.done { return }
        progress = next.done < next.total ? next : nil
        // Results grow while the index fills: search again every hundred sessions read.
        if next.indexed - refreshedAtIndexed >= 100 {
            refreshedAtIndexed = next.indexed
            refresh()
        }
    }

    // MARK: Searching

    /// Searches for `text`; an empty text clears the hits.
    func search(_ text: String) {
        guard text != query || hits.isEmpty else { return }
        query = text
        refresh()
    }

    private func refresh() {
        searchJob?.cancel()
        let text = query
        let parsed = SearchQuery(text)
        guard !parsed.isEmpty, let index = openIndex() else {
            if !hits.isEmpty {
                hits = [:]
                revision += 1
            }
            isSearching = false
            return
        }
        isSearching = true
        searchJob = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { try? await index.search(parsed, limit: 5_000) }.value
            guard let self, !Task.isCancelled, text == query else { return }
            hits = Dictionary((found ?? []).map { (Self.key($0.agent, $0.sessionID), $0) }, uniquingKeysWith: { first, _ in first })
            isSearching = false
            revision += 1
        }
    }

    /// The hit for `session` in the current transcript search, if it matched.
    func hit(for session: Session) -> TranscriptHit? {
        guard scope == .transcripts, !query.isEmpty else { return nil }
        return hits[Self.key(session.agent, session.id)]
    }

    /// The parsed query while a transcript search is showing.
    var activeQuery: SearchQuery? {
        guard scope == .transcripts else { return nil }
        let parsed = SearchQuery(query)
        return parsed.isEmpty ? nil : parsed
    }

    /// Rows that match, best first when `byRelevance` (no column sort was picked).
    func filter(_ rows: [SessionRow], byRelevance: Bool) -> [SessionRow] {
        let matching = rows.filter { hits[Self.key($0.session.agent, $0.session.id)] != nil }
        guard byRelevance else { return matching }
        return matching.sorted { a, b in
            (hits[Self.key(a.session.agent, a.session.id)]?.score ?? 0) > (hits[Self.key(b.session.agent, b.session.id)]?.score ?? 0)
        }
    }

    /// Whether results for `text` are still on their way (searching, or the index filling).
    func isPending(for text: String) -> Bool {
        isSearching || text != query || progress != nil
    }

    /// "Indexing 312 of 900 sessions…", while the index fills.
    var progressText: String? {
        progress.map { "Indexing \($0.done.formatted()) of \($0.total.formatted()) sessions\u{2026}" }
    }

    private static func key(_ agent: AgentKind, _ id: String) -> String { agent.rawValue + "/" + id }
}

/// Titles or Transcripts, beside the search chip in the filter bar, with the index's progress.
struct SearchScopeControl: View {
    @Environment(SessionLibrary.self) private var library

    var body: some View {
        @Bindable var search = library.transcriptSearch
        if search.isAllowed { control(search) }
    }

    private func control(_ search: TranscriptSearch) -> some View {
        @Bindable var search = search
        return HStack(spacing: 8) {
            Picker("Search in", selection: $search.scope) {
                ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Search session titles and projects, or everything said in the transcripts")
            if search.scope == .transcripts {
                if let failure = search.failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(failure)
                } else if let text = search.progressText {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(text)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    Button("Stop", systemImage: "stop.circle", action: search.cancelIndexing)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Stop indexing; it carries on after the next reload")
                } else {
                    Button("Rebuild Index", systemImage: "arrow.clockwise", action: search.rebuild)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Read every transcript again to rebuild the local search index")
                }
            }
        }
    }
}

/// While a transcript search waits for the index or the query, in place of "No Results".
struct TranscriptSearchPending: View {
    let text: String?

    var body: some View {
        ContentUnavailableView {
            Label("Searching transcripts\u{2026}", systemImage: "text.magnifyingglass")
        } description: {
            Text(text ?? "Looking through what was said in every session.")
        }
    }
}

/// Where a transcript search matched the transcript on screen: the message to scroll to and
/// the snippet for the header. Worked out off the main actor from the transcript already read.
struct TranscriptMatch: Equatable, Sendable {
    struct Key: Hashable {
        let loaded: Session.ID?
        let count: Int
        let query: SearchQuery?
        let first: Int?
    }

    let sessionID: Session.ID
    let targetID: TranscriptMessage.ID?
    let snippet: SearchSnippet?

    static func find(in transcript: Transcript, sessionID: Session.ID, query: SearchQuery, preferring index: Int?) async -> TranscriptMatch {
        await Task.detached(priority: .userInitiated) {
            let snippet = SearchSnippet.make(from: transcript, query: query, preferring: index)
            let target = snippet.map { transcript.messages[$0.messageIndex].id }
            return TranscriptMatch(sessionID: sessionID, targetID: target, snippet: snippet)
        }.value
    }
}

/// "3 messages match", with the first match in context, above the transcript.
struct SearchMatchHeader: View {
    let hit: TranscriptHit
    let match: TranscriptMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(hit.matchCount) \(hit.matchCount == 1 ? "message matches" : "messages match")", systemImage: "text.magnifyingglass")
                .font(.callout.weight(.medium))
            if let snippet = match.snippet {
                Text(Self.attributed(snippet))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if match.targetID == nil {
                Text("The match is further into the transcript than Domovy shows here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    static func attributed(_ snippet: SearchSnippet) -> AttributedString {
        var result = AttributedString(snippet.text)
        for range in snippet.highlights {
            let start = snippet.text.distance(from: snippet.text.startIndex, to: range.lowerBound)
            let length = snippet.text.distance(from: range.lowerBound, to: range.upperBound)
            let lower = result.characters.index(result.startIndex, offsetBy: start)
            let upper = result.characters.index(lower, offsetBy: length)
            result[lower..<upper].backgroundColor = Color.accentColor.opacity(0.3)
            result[lower..<upper].foregroundColor = .primary
        }
        return result
    }
}
