import os

/// Shared loggers. Paths and transcript content are always logged as `.private`.
enum Log {
    static let subsystem = "com.turman.domovy"

    static let adapter = Logger(subsystem: subsystem, category: "adapter")
    static let executor = Logger(subsystem: subsystem, category: "executor")
    static let liveness = Logger(subsystem: subsystem, category: "liveness")
    /// Counts only. Use `SecretsLog`, which takes nothing but numbers.
    static let secrets = Logger(subsystem: subsystem, category: "secrets")
}
