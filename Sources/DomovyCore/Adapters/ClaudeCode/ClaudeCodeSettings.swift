import Foundation

/// The few settings Domovy needs from `settings.json`.
struct ClaudeCodeSettings: Sendable {
    /// Claude Code's documented default when `cleanupPeriodDays` is absent.
    static let defaultCleanupPeriodDays = 30

    let cleanupPeriodDays: Int

    static func load(from url: URL) -> ClaudeCodeSettings {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeCodeSettings(cleanupPeriodDays: defaultCleanupPeriodDays)
        }
        let days: Int
        switch object["cleanupPeriodDays"] {
        case let value as Int: days = value
        case let value as Double: days = Int(value)
        default: days = defaultCleanupPeriodDays
        }
        // The minimum Claude Code accepts is 1; anything else means "use the default".
        return ClaudeCodeSettings(cleanupPeriodDays: days >= 1 ? days : defaultCleanupPeriodDays)
    }
}
