import Foundation

/// Gemini CLI's chat retention, from `general.sessionRetention` in `~/.gemini/settings.json`.
/// Verified in the 0.43.0 source: on by default, `maxAge` "30d" (units h, d, w, m = 30 days),
/// optional `maxCount` per project; an invalid value turns the sweep off. Each project is swept
/// when Gemini CLI starts there, keyed on the chat's last update. A project's own
/// `.gemini/settings.json` can override this; Domovy reads only the user settings.
struct GeminiSettings: Sendable {
    static let defaultMaxAge = "30d"

    /// `nil` when the sweep is off or its settings are invalid.
    let maxAge: TimeInterval?
    let maxAgeText: String
    /// Newest chats kept per project, when set.
    let maxCount: Int?
    let isEnabled: Bool

    static func load(from url: URL) -> GeminiSettings {
        let object = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let retention = (object?["general"] as? [String: Any])?["sessionRetention"] as? [String: Any] ?? [:]
        let enabled = retention["enabled"] as? Bool ?? true
        let text = retention["maxAge"] as? String ?? defaultMaxAge
        let count = (retention["maxCount"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        let age = parse(text)
        // Gemini CLI turns cleanup off when maxAge is invalid.
        let valid = retention["maxAge"] == nil || age != nil
        return GeminiSettings(maxAge: enabled && valid ? age : nil, maxAgeText: text, maxCount: enabled && valid ? count : nil, isEnabled: enabled && valid)
    }

    /// "30d", "12h", "2w", "1m" (30 days), as Gemini CLI's `parseRetentionPeriod`.
    static func parse(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let value = Int(text.dropLast()), value > 0 else { return nil }
        let hour: TimeInterval = 3_600
        switch unit {
        case "h": return TimeInterval(value) * hour
        case "d": return TimeInterval(value) * 24 * hour
        case "w": return TimeInterval(value) * 7 * 24 * hour
        case "m": return TimeInterval(value) * 30 * 24 * hour
        default: return nil
        }
    }

    /// "30 days", "12 hours", "2 weeks", "1 month".
    var maxAgeDescription: String {
        guard let unit = maxAgeText.last, let value = Int(maxAgeText.dropLast()) else { return maxAgeText }
        let word = switch unit {
        case "h": "hour"
        case "w": "week"
        case "m": "month"
        default: "day"
        }
        return "\(value) \(word)\(value == 1 ? "" : "s")"
    }
}
