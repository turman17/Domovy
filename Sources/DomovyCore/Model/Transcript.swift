import Foundation

/// A bounded, display-only view of a session's conversation. Transcripts may hold secrets:
/// values of this type are shown on screen and never logged or written anywhere.
public struct Transcript: Hashable, Sendable {
    public let messages: [TranscriptMessage]
    /// True when the file holds more than was read.
    public let isTruncated: Bool
    /// Lines left out because they hold a possible secret that could not be masked.
    public let hiddenLineCount: Int
    /// For a page read from the end: where the older messages before it end; `nil` when the
    /// page starts at the beginning of the conversation.
    public let olderCursor: TranscriptCursor?

    public init(messages: [TranscriptMessage], isTruncated: Bool, hiddenLineCount: Int = 0, olderCursor: TranscriptCursor? = nil) {
        self.messages = messages
        self.isTruncated = isTruncated
        self.hiddenLineCount = hiddenLineCount
        self.olderCursor = olderCursor
    }

    public static let empty = Transcript(messages: [], isTruncated: false)
}

/// Where a page of a transcript ends, as its adapter counts: a byte offset of the first line
/// of the newer page for line-based files, a message index otherwise.
public struct TranscriptCursor: Hashable, Sendable {
    public let position: Int64

    public init(_ position: Int64) {
        self.position = position
    }
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
