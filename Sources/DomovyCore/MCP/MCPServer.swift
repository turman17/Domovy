import Foundation
import os

/// A minimal Model Context Protocol server: JSON-RPC 2.0 over stdio, one message per line
/// (MCP revision 2025-06-18). It answers `initialize`, `ping`, `tools/list` and `tools/call`,
/// and ignores notifications. Everything a tool does is in `DomovyTools`.
///
/// stdout carries protocol messages only. Nothing about sessions or transcripts is logged.
public actor MCPServer {
    public static let protocolVersion = "2025-06-18"
    /// Revisions whose subset used here is the same; a client asking for one gets it back.
    static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public static let serverVersion = DomovyVersion.current

    private let tools: DomovyTools
    private var initialized = false
    private let logger = Logger(subsystem: "com.turman.domovy", category: "mcp")

    public init(tools: DomovyTools) {
        self.tools = tools
    }

    /// Reads messages from `input` until it closes and writes each reply to `output`.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        do {
            for try await line in input.bytes.lines {
                guard let reply = await handle(Data(line.utf8)) else { continue }
                output.write(reply + Data("\n".utf8))
            }
        } catch {
            logger.error("stdin closed with an error")
        }
    }

    /// One incoming message; the reply to write, or `nil` for a notification.
    public func handle(_ data: Data) async -> Data? {
        let trimmed = data.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed)) else {
            return Self.error(id: .null, code: -32700, message: "Parse error: the message is not JSON.")
        }
        guard case .object(let fields) = message, fields["jsonrpc"]?.stringValue == "2.0",
              let method = fields["method"]?.stringValue else {
            // A response from the client (we send no requests) or something malformed.
            if case .object(let fields) = message, fields["method"] == nil, fields["id"] != nil { return nil }
            return Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid request.")
        }
        guard let id = fields["id"] else {
            if method == "notifications/initialized" { initialized = true }
            return nil
        }
        let params = fields["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.protocolVersion
            let version = Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion
            logger.info("initialize, protocol \(version, privacy: .public)")
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "domovy", "title": "Domovy", "version": .string(Self.serverVersion)],
                "instructions": .string(DomovyTools.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(DomovyTools.definitions.map(\.json))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "Invalid params: tools/call needs a tool name.")
            }
            guard DomovyTools.definitions.contains(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            logger.info("tools/call \(name, privacy: .public)")
            let outcome = await tools.call(name, arguments: params["arguments"]?.objectValue ?? [:])
            return Self.result(id: id, outcome.json)
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ result: [String: JSONValue]) -> Data {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": .object(result)]).encoded()
    }

    static func error(id: JSONValue, code: Int, message: String) -> Data {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]).encoded()
    }
}

/// What a tool returns: text for the model, the same facts as structured content, and whether
/// it failed (a tool error the model sees, not a protocol error).
public struct ToolOutcome: Sendable {
    public let text: String
    public let structured: JSONValue
    public let isError: Bool

    public init(text: String, structured: JSONValue, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    public static func failure(_ text: String) -> ToolOutcome {
        ToolOutcome(text: text, structured: ["error": .string(text)], isError: true)
    }

    var json: [String: JSONValue] {
        [
            "content": [["type": "text", "text": .string(text)]],
            "structuredContent": structured,
            "isError": .bool(isError),
        ]
    }
}

/// One tool as `tools/list` describes it.
public struct ToolDefinition: Sendable {
    public struct Annotations: Sendable {
        let readOnly: Bool
        let destructive: Bool
        let idempotent: Bool

        static let readOnly = Annotations(readOnly: true, destructive: false, idempotent: true)
    }

    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: Annotations

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(annotations.readOnly),
                "destructiveHint": .bool(annotations.destructive),
                "idempotentHint": .bool(annotations.idempotent),
                "openWorldHint": false,
            ],
        ]
    }
}
