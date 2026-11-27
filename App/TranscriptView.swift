import DomovyCore
import SwiftUI

/// The conversation as a clean chat: user prompts in tinted bubbles, assistant text plain,
/// tool calls as one-line chips. Opens at the newest message and loads older pages as the
/// reader scrolls up, like a chat; content is only shown.
struct TranscriptView: View {
    let session: Session

    @Environment(SessionLibrary.self) private var library
    /// The last transcript read, kept on screen (faded) while the next one loads, so stepping
    /// through rows does not flash a spinner.
    @State private var loaded: LoadedTranscript?
    @State private var pace = LoadPace()
    /// Why the transcript of that session could not be read.
    @State private var failure: (sessionID: Session.ID, message: String)?
    /// Where the transcript search matched this transcript.
    @State private var match: TranscriptMatch?
    /// Older pages load only once the newest one sits at the bottom, so the first layout does
    /// not pull every page in.
    @State private var canLoadOlder = false
    @State private var isLoadingOlder = false
    /// The message to keep at the top after older ones were put above it.
    @State private var keepInView: ScrollRequest?
    /// Older pages read in a row while looking for the search match.
    @State private var searchPages = 0

    static let pageSize = 200
    /// How far back a search match is looked for before the header says it is further in.
    static let searchPageLimit = 20

    /// Read again when a scan finds or clears secrets, so the masks follow the findings.
    private var key: String {
        "\(session.id)#\(library.findings(for: session).map(\.id).joined(separator: ","))"
    }

    private var hit: TranscriptHit? { library.transcriptSearch.hit(for: session) }
    private var searchQuery: SearchQuery? { hit == nil ? nil : library.transcriptSearch.activeQuery }

    var body: some View {
        let isCurrent = loaded?.sessionID == session.id
        let failure = self.failure?.sessionID == session.id ? self.failure?.message : nil
        let match = self.match?.sessionID == session.id && isCurrent ? self.match : nil
        VStack(spacing: 0) {
        if let match, let hit {
            SearchMatchHeader(hit: hit, match: match)
            Divider()
        }
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if failure != nil || loaded == nil {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                } else if let loaded {
                    olderHeader(loaded)
                    ForEach(loaded.messages) { message in
                        MessageView(message: message)
                    }
                    if loaded.hiddenLineCount > 0 {
                        Label("\(loaded.hiddenLineCount) \(loaded.hiddenLineCount == 1 ? "line is" : "lines are") hidden: \(loaded.hiddenLineCount == 1 ? "it holds" : "they hold") a possible secret Domovy cannot mask.", systemImage: "key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    if loaded.isCutBeforeEnd {
                        Text("This transcript is too long to read to the end. Showing its first \(loaded.messages.count) messages.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    } else if loaded.messages.isEmpty {
                        Text("No readable messages in this transcript.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                }
            }
            .padding(16)
            .environment(\.searchHighlight, searchQuery)
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: match?.targetID) { _, target in
            if let target { proxy.scrollTo(target, anchor: .top) }
        }
        .onChange(of: keepInView) { _, request in
            if let request { proxy.scrollTo(request.messageID, anchor: .top) }
        }
        .onChange(of: loaded?.firstPageID) { _, _ in
            // A new page from the end: start at the newest message.
            guard let last = loaded?.messages.last?.id else { return }
            if searchQuery == nil { proxy.scrollTo(last, anchor: .bottom) }
        }
        }
        // A new session starts at the bottom; a re-read of the same one keeps the scroll position.
        .id(loaded?.sessionID)
        .opacity(isCurrent || loaded == nil ? 1 : 0.4)
        .allowsHitTesting(isCurrent)
        .accessibilityHidden(!isCurrent && loaded != nil)
        .task(id: key) {
            // Holding an arrow key selects a row every few milliseconds: wait for it to rest
            // before reading. Adapter reads cannot be cancelled once started, so a result that
            // arrives for a row no longer shown is dropped.
            guard await pace.wait() else { return }
            let session = self.session
            canLoadOlder = false
            searchPages = 0
            do {
                let page = try await library.transcriptPage(of: session, limit: Self.pageSize, before: nil)
                let messages = await Task.detached { page.messages.map(RenderedMessage.init) }.value
                guard !Task.isCancelled else { return }
                loaded = LoadedTranscript(sessionID: session.id, first: page, messages: messages)
                self.failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                loaded = nil
                self.failure = (session.id, error.localizedDescription)
            }
            #if DEBUG
            PerfDriver.shared.transcriptLoaded = session.id
            #endif
            await allowOlderSoon()
        }
        .task(id: TranscriptMatch.Key(loaded: loaded?.sessionID, count: loaded?.messages.count ?? 0, query: searchQuery, first: hit?.firstMessage)) {
            guard let loaded, let query = searchQuery else {
                self.match = nil
                return
            }
            // The search index counts messages from the start; that only holds once the first
            // message is loaded.
            let preferred = loaded.olderCursor == nil ? hit?.firstMessage : nil
            let found = await TranscriptMatch.find(in: loaded.transcript, sessionID: loaded.sessionID, query: query, preferring: preferred)
            guard !Task.isCancelled else { return }
            self.match = found
            if found.targetID == nil, loaded.olderCursor != nil, searchPages < Self.searchPageLimit {
                searchPages += 1
                await loadOlder()
            }
        }
        }
    }

    /// The top of the list: a spinner that loads the page before when it scrolls into view,
    /// or where the conversation starts.
    @ViewBuilder
    private func olderHeader(_ loaded: LoadedTranscript) -> some View {
        if loaded.olderCursor != nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityLabel("Loading earlier messages")
                .task(id: OlderKey(ready: canLoadOlder, cursor: loaded.olderCursor)) {
                    guard canLoadOlder else { return }
                    await loadOlder()
                }
        } else if !loaded.messages.isEmpty {
            Text("Start of the conversation")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Puts the page before the oldest message on screen above it, keeping that message where it was.
    private func loadOlder() async {
        guard let cursor = loaded?.olderCursor, loaded?.sessionID == session.id, !isLoadingOlder else { return }
        isLoadingOlder = true
        canLoadOlder = false
        defer { isLoadingOlder = false }
        let session = self.session
        do {
            let page = try await library.transcriptPage(of: session, limit: Self.pageSize, before: cursor)
            let messages = await Task.detached { page.messages.map(RenderedMessage.init) }.value
            guard let latest = loaded, latest.sessionID == session.id, latest.olderCursor == cursor else { return }
            let anchor = latest.messages.first?.id
            loaded = latest.prepending(page, messages: messages)
            if let anchor, searchQuery == nil || match?.targetID != nil { keepInView = ScrollRequest(messageID: anchor) }
        } catch {
            // The file changed or went away: stop paging, keep what is shown.
            guard let latest = loaded, latest.sessionID == session.id else { return }
            loaded = latest.endingPaging()
        }
        await allowOlderSoon()
    }

    private func allowOlderSoon() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        canLoadOlder = true
    }
}

private struct OlderKey: Hashable {
    let ready: Bool
    let cursor: TranscriptCursor?
}

private struct ScrollRequest: Equatable {
    let messageID: TranscriptMessage.ID
    let token = UUID()
}

/// The pages read so far, oldest first, with their markdown parsed once, off the main actor.
private struct LoadedTranscript {
    let sessionID: Session.ID
    /// Identifies the newest page, so a fresh read scrolls to the bottom.
    let firstPageID: UUID
    private(set) var transcript: Transcript
    private(set) var messages: [RenderedMessage]
    private(set) var olderCursor: TranscriptCursor?
    private(set) var hiddenLineCount: Int
    /// The agent's reader stopped before the newest message.
    let isCutBeforeEnd: Bool

    init(sessionID: Session.ID, first page: Transcript, messages: [RenderedMessage]) {
        self.sessionID = sessionID
        firstPageID = UUID()
        transcript = page
        self.messages = messages
        olderCursor = page.olderCursor
        hiddenLineCount = page.hiddenLineCount
        isCutBeforeEnd = page.isTruncated
    }

    func prepending(_ page: Transcript, messages older: [RenderedMessage]) -> LoadedTranscript {
        var next = self
        let known = Set(messages.map(\.id))
        let fresh = page.messages.filter { !known.contains($0.id) }
        next.transcript = Transcript(messages: fresh + transcript.messages, isTruncated: transcript.isTruncated,
                                     hiddenLineCount: hiddenLineCount + page.hiddenLineCount, olderCursor: page.olderCursor)
        next.messages = older.filter { !known.contains($0.id) } + messages
        next.olderCursor = page.olderCursor
        next.hiddenLineCount += page.hiddenLineCount
        return next
    }

    func endingPaging() -> LoadedTranscript {
        var next = self
        next.olderCursor = nil
        return next
    }
}

private struct RenderedMessage: Identifiable, Sendable {
    enum Part: Sendable {
        case text(String, [MarkdownBlock])
        case toolCall(String)
    }

    let id: TranscriptMessage.ID
    let role: TranscriptMessage.Role
    let parts: [Part]

    init(_ message: TranscriptMessage) {
        id = message.id
        role = message.role
        parts = message.blocks.map { block in
            switch block {
            case .text(let text): .text(text, MarkdownBlock.parse(text))
            case .toolCall(let summary): .toolCall(summary)
            }
        }
    }
}

private struct MessageView: View {
    let message: RenderedMessage

    var body: some View {
        ForEach(message.parts.indices, id: \.self) { index in
            switch message.parts[index] {
            case .text(let text, let blocks):
                if message.role == .user {
                    MarkdownView(blocks: blocks)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("You: \(text)")
                } else {
                    MarkdownView(blocks: blocks)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Assistant: \(text)")
                }
            case .toolCall(let summary):
                ToolCallChip(summary: summary)
            }
        }
    }
}

/// "Edit src/components/Hero.tsx": tool name in the UI font, its argument monospaced.
private struct ToolCallChip: View {
    let summary: String

    private var parts: (name: String, detail: String?) {
        guard let space = summary.firstIndex(of: " ") else { return (summary, nil) }
        return (String(summary[..<space]), String(summary[summary.index(after: space)...]))
    }

    private var symbol: String {
        switch parts.name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "doc"
        case "Read": "doc.text"
        case "Bash": "terminal"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        default: "wrench"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(parts.name)
                .foregroundStyle(.secondary)
            if let detail = parts.detail {
                Text(detail)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tool call: \(summary)")
    }
}

/// Space bar quick look: the same chat, larger, closed with Space or Escape.
struct TranscriptPreviewSheet: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle).font(.headline).lineLimit(1)
                    Text("\(session.agent.displayName) · \(session.projectName ?? "no project")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            TranscriptView(session: session)
        }
        .frame(minWidth: 640, idealWidth: 920, maxWidth: .infinity, minHeight: 540, idealHeight: 720, maxHeight: .infinity)
        .onKeyPress(.space) {
            dismiss()
            return .handled
        }
    }
}
