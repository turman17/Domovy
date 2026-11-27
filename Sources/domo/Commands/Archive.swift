import ArgumentParser
import DomovyCore
import Foundation

struct Archive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compress cold sessions in place so they take less disk.",
        discussion: """
        Claude Code sessions: APFS transparent compression; Claude Code reads the files unchanged and can still resume the session. \
        Modification times are kept, so Claude Code's own cleanup still applies on schedule. \
        Codex sessions: runs `codex archive` when the codex CLI is installed (Codex must be quit), else compresses in place. \
        Gemini CLI chats: APFS compression in place, like Claude Code. Antigravity is read-only for now. \
        Name sessions by id, or select them with --older, --agent and --project (idle sessions only). \
        `domo undo` reverses either. `--dry-run --json` and `-y --if-plan <digest>` work as for `domo rm`.
        """
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "Session ids or unique prefixes of them (see `domo ls`).")
    var ids: [String] = []

    @OptionGroup var filters: SessionFilters

    @OptionGroup var flags: PlanFlags

    func run() async throws {
        do {
            // Read-only agents (Antigravity) have nothing to archive; Codex sessions already in
            // archived_sessions have nothing left to archive.
            let ids = try await options.sessionIDs(ids, filters: filters) { scan, session in
                scan.status == .ready && !(session.agent == .codex && session.isArchived)
            }
            try await PlanRunner.run(.archive, sessionIDs: ids, destination: nil, flags: flags, acceptLimitedUndo: false, options: options)
        } catch let error as ExitCode {
            throw error
        } catch let error as ValidationError {
            throw error
        } catch {
            throw Domo.fail(error)
        }
    }
}

/// "30d", "2w" or "12h".
struct AgeThreshold: ExpressibleByArgument {
    let seconds: TimeInterval
    let text: String

    init?(argument: String) {
        let units: [Character: TimeInterval] = ["h": 3_600, "d": 86_400, "w": 604_800]
        guard let unit = argument.last, let factor = units[unit], let value = Double(argument.dropLast()), value > 0 else { return nil }
        seconds = value * factor
        text = argument
    }
}
