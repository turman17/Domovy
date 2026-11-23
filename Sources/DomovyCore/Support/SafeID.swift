import Foundation

/// Ids read from an agent's own data (database rows, JSON) before Domovy turns them into a path
/// or a command-line argument. A crafted id such as `../../Documents/x` would point a move
/// outside the agent's folder, and one starting with `-` would read as an option.
enum SafeID {
    /// Letters, digits, `-`, `_` and `.`; not empty, not starting with `-` or `.`, at most 255
    /// bytes. No `/`, no `:` (Cursor keys rows `<prefix>:<id>:<item>`), no spaces.
    static func isSafe(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 255, let first = id.first, first != "-", first != "." else { return false }
        return id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" || $0 == "." }
    }
}
