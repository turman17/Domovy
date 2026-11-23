import Foundation

/// A bounded, display-only view of a session's conversation. Transcripts may hold secrets:
/// values of this type are shown on screen and never logged or written anywhere.
public struct Transcript: Hashable, Sendable {
    public let messages: [TranscriptMessage]
    /// True when the file holds more than was read.
    public let isTruncated: Bool

    public init(messages: [TranscriptMessage], isTruncated: Bool) {
        self.messages = messages
        self.isTruncated = isTruncated
    }

    public static let empty = Transcript(messages: [], isTruncated: false)
}

public struct TranscriptMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public enum Block: Hashable, Sendable {
        case text(String)
        /// One-line summary of a tool call, e.g. "Edit src/App.swift".
        case toolCall(String)
    }

    public let id: String
    public let role: Role
    public let timestamp: Date?
    public let blocks: [Block]

    public init(id: String, role: Role, timestamp: Date?, blocks: [Block]) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.blocks = blocks
    }
}
