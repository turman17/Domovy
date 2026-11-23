import Foundation

/// Chats without messages that share one session id, shown and deleted as one row. Gemini CLI's
/// a2a server writes them by the hundred (427 on the machine the layout was verified on), all
/// under its one id, most of them a header line and nothing else.
struct GeminiChatGroup: Sendable {
    struct Member: Sendable {
        let project: GeminiProject
        let chat: GeminiProject.Chat
    }

    /// The shared session id, as Gemini CLI wrote it.
    let sessionID: String
    let members: [Member]

    /// The row's id: the shared id plus `-empty`, never the id of a single chat.
    var id: String { sessionID.lowercased() + Self.idSuffix }
    static let idSuffix = "-empty"

    var title: String {
        let n = members.count
        return sessionID.lowercased().hasPrefix("a2a-server")
            ? "\(n) empty chats from Gemini's a2a server"
            : "\(n) empty chats with session id \(sessionID)"
    }

    /// The project path when every chat belongs to the same project.
    var projectPath: String? {
        let paths = Set(members.map { $0.project.path ?? "" })
        return paths.count == 1 ? members.first?.project.path : nil
    }

    var newest: Member? { members.max { $0.chat.lastActive < $1.chat.lastActive } }

    /// Groups of at least `minimum` chats: main chats (not subagents) without user or model
    /// messages, by session id across all projects.
    static func groups(in projects: [GeminiProject], minimum: Int = 2) -> [GeminiChatGroup] {
        var byID: [String: [Member]] = [:]
        for project in projects {
            for chat in project.chats where !chat.header.hasMessages && chat.header.kind != "subagent" {
                guard let id = chat.header.sessionID else { continue }
                byID[id, default: []].append(Member(project: project, chat: chat))
            }
        }
        return byID.filter { $0.value.count >= minimum }
            .map { GeminiChatGroup(sessionID: $0.key, members: $0.value.sorted { $0.chat.file.path < $1.chat.file.path }) }
            .sorted { $0.sessionID < $1.sessionID }
    }
}
