import ArgumentParser
import DomovyCore
import Foundation

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search inside session transcripts.",
        discussion: """
        Words match any word they start (auth finds authentication); "double quotes" match a phrase. \
        Uses Domovy's local index, updated first with whatever changed. Snippets have secrets masked.
        """
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "What to find.")
    var query: [String] = []

    @Option(name: .long, help: "Only this agent (claude-code, codex, gemini, ...).")
    var agent: String?

    @Option(name: .long, help: "At most this many sessions.")
    var limit = 20

    @Flag(name: .long, help: "Print full session ids instead of the first 8 characters.")
    var full = false

    @Flag(name: .long, help: "Empty the index and build it again from every transcript.")
    var rebuild = false

    func run() async throws {
        let text = query.joined(separator: " ")
        do {
            var kind: AgentKind?
            if let agent {
                guard let parsed = RuleAgentID.parse(agent) else {
                    throw ValidationError("Unknown agent \(agent). Use one of: \(RuleAgentID.all.joined(separator: ", ")).")
                }
                kind = parsed
            }
            guard rebuild || !SearchQuery(text).isEmpty else { throw ValidationError("Give at least one word to search for.") }
            let context = DomovyContext(home: options.home, isCustomHome: options.root != nil)
            let searcher = TranscriptSearcher(context: context)
            let index = try searcher.openIndex()
            if rebuild { try await index.removeAll() }
            let started = ContinuousClock.now
            let showsProgress = isatty(STDERR_FILENO) != 0
            let results = try await searcher.search(text, agent: kind, limit: max(1, limit), index: index) { progress in
                guard showsProgress, progress.indexed > 0 || progress.done == progress.total else { return }
                FileHandle.standardError.write(Data("\rIndexing \(progress.done) of \(progress.total) sessions\u{2026}".utf8))
            }
            if showsProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
            if rebuild, SearchQuery(text).isEmpty {
                print("Rebuilt the search index (\(try await index.count()) sessions) in \(started.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds]))).")
                return
            }
            guard !results.isEmpty else {
                print("No session mentions that.")
                return
            }
            let bold = isatty(STDOUT_FILENO) != 0
            for result in results {
                let s = result.session
                let matches = "\(result.hit.matchCount) \(result.hit.matchCount == 1 ? "match" : "matches")"
                print("\(full ? s.id : Format.shortID(s.id))  \(s.agentLabel)  \(Format.relative(s.lastActive))  \(matches)  \(s.displayTitle.replacingOccurrences(of: "\n", with: " "))")
                if let snippet = await searcher.snippet(for: result, query: text) {
                    print("    \(Self.render(snippet, bold: bold))")
                }
            }
        } catch let error as ValidationError {
            throw error
        } catch {
            throw Domo.fail(error)
        }
    }

    /// The snippet with matches in bold on a terminal, in «» otherwise.
    static func render(_ snippet: SearchSnippet, bold: Bool) -> String {
        var output = ""
        var position = snippet.text.startIndex
        for range in snippet.highlights {
            output += snippet.text[position..<range.lowerBound]
            output += bold ? "\u{1B}[1m\(snippet.text[range])\u{1B}[22m" : "\u{00AB}\(snippet.text[range])\u{00BB}"
            position = range.upperBound
        }
        return output + snippet.text[position...]
    }
}
