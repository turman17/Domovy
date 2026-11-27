import Foundation

/// Adds and removes one member of a JSON (or JSONC: comments, trailing commas) config file
/// without re-serializing anything else. Every byte outside the inserted member stays as it
/// was, so removing what was inserted gives back the original file.
enum JSONCEditor {
    enum EditError: Error, Equatable {
        case notAnObject
        case malformed(Int)
        case notAnObjectAt(String)
    }

    struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
    }

    struct Object {
        let open: Int
        let close: Int
        let members: [Member]
    }

    /// What an insert did, so the matching removal can undo it exactly.
    struct Insertion: Hashable, Codable, Sendable {
        /// How many objects on the path did not exist and were created with the member.
        var createdContainers: Int
        /// The whitespace an empty object held before the member went in.
        var originalInner: String?
    }

    // MARK: Reading

    /// The value of `key` in the object at `path`, comments removed. `nil` when absent.
    static func value(of key: String, at path: [String], in data: Data) throws -> JSONValue? {
        let bytes = [UInt8](data)
        guard let object = try descend(bytes, path: path).object,
              let member = object.members.last(where: { $0.key == key }) else { return nil }
        let slice = Data(strip(Array(bytes[member.valueStart..<member.valueEnd])))
        return try? JSONDecoder().decode(JSONValue.self, from: slice)
    }

    /// Whether the object at `path` exists and has `key`.
    static func contains(_ key: String, at path: [String], in data: Data) throws -> Bool {
        try descend([UInt8](data), path: path).object?.members.contains { $0.key == key } ?? false
    }

    /// The members of the object at `path` (keys and values), for matching existing entries.
    static func memberValues(at path: [String], in data: Data) throws -> [String: JSONValue] {
        let bytes = [UInt8](data)
        guard let object = try descend(bytes, path: path).object else { return [:] }
        var result: [String: JSONValue] = [:]
        for member in object.members {
            let slice = Data(strip(Array(bytes[member.valueStart..<member.valueEnd])))
            result[member.key] = (try? JSONDecoder().decode(JSONValue.self, from: slice)) ?? .null
        }
        return result
    }

    // MARK: Writing

    /// `data` with `key: value` added to the object at `path`, creating missing objects on the
    /// way. An empty or missing file becomes a new object. Fails if `key` is already there.
    static func inserting(_ key: String, value: OrderedJSON, at path: [String], in data: Data) throws -> (data: Data, insertion: Insertion) {
        var bytes = [UInt8](data)
        if bytes.allSatisfy(isSpace) {
            let unit = "  "
            let top = member(path + [key], value)
            let text = render(key: top.key, value: top.value, indent: unit, unit: unit)
            return (Data(("{\n" + unit + text + "\n}\n").utf8), Insertion(createdContainers: path.count, originalInner: nil))
        }
        let found = try descend(bytes, path: path)
        let missing = Array(path.dropFirst(found.depth))
        let target = found.deepest
        let (memberKey, memberValue) = member(missing + [key], value)
        if missing.isEmpty, target.members.contains(where: { $0.key == key }) { throw EditError.malformed(target.open) }
        let unit = indentUnit(bytes)
        var insertion = Insertion(createdContainers: missing.count, originalInner: nil)
        if let last = target.members.last, let first = target.members.first {
            if let indent = lineIndent(bytes, at: first.keyStart, after: target.open) {
                let text = ",\n" + indent + render(key: memberKey, value: memberValue, indent: indent, unit: unit)
                bytes.insert(contentsOf: Array(text.utf8), at: last.valueEnd)
            } else {
                let text = ", " + renderInline(key: memberKey, value: memberValue)
                bytes.insert(contentsOf: Array(text.utf8), at: last.valueEnd)
            }
        } else {
            let parent = lineIndentOfLine(bytes, containing: target.open)
            let child = parent + unit
            insertion.originalInner = String(decoding: bytes[(target.open + 1)..<target.close], as: UTF8.self)
            let text = "\n" + child + render(key: memberKey, value: memberValue, indent: child, unit: unit) + "\n" + parent
            bytes.replaceSubrange((target.open + 1)..<target.close, with: Array(text.utf8))
        }
        return (Data(bytes), insertion)
    }

    /// `data` with the value of `key` in the object at `path` replaced, everything else kept.
    static func replacingValue(of key: String, with value: OrderedJSON, at path: [String], in data: Data) throws -> Data? {
        var bytes = [UInt8](data)
        guard let object = try descend(bytes, path: path).object,
              let member = object.members.last(where: { $0.key == key }) else { return nil }
        let indent = lineIndentOfLine(bytes, containing: member.keyStart)
        let text = renderValue(value, indent: indent, unit: indentUnit(bytes))
        bytes.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(text.utf8))
        return Data(bytes)
    }

    /// `data` without `key` in the object at `path`; `nil` when it is not there. With the
    /// `insertion` that added it, objects created for it go too and an emptied object gets its
    /// old whitespace back.
    static func removing(_ key: String, at path: [String], in data: Data, insertion: Insertion? = nil) throws -> Data? {
        let bytes = [UInt8](data)
        guard let object = try descend(bytes, path: path).object, object.members.contains(where: { $0.key == key }) else { return nil }
        // Drop the outermost created container if nothing else went into it since.
        var created = min(insertion?.createdContainers ?? 0, path.count)
        while created > 0 {
            let containerPath = Array(path.prefix(path.count - created + 1))
            if try onlyChain(bytes, from: containerPath, rest: Array(path.dropFirst(containerPath.count)), key: key) { break }
            created -= 1
        }
        let removePath = Array(path.prefix(path.count - created))
        let removeKey = created > 0 ? path[path.count - created] : key
        guard let parent = try descend(bytes, path: removePath).object,
              let index = parent.members.lastIndex(where: { $0.key == removeKey }) else { return nil }
        return Data(cut(bytes, member: index, of: parent, emptyInner: insertion?.originalInner ?? ""))
    }

    /// Whether the object at `path` holds nothing but the chain down to `key`.
    private static func onlyChain(_ bytes: [UInt8], from path: [String], rest: [String], key: String) throws -> Bool {
        guard let object = try descend(bytes, path: path).object, object.members.count == 1 else { return false }
        guard let next = rest.first else { return object.members[0].key == key }
        return object.members[0].key == next ? try onlyChain(bytes, from: path + [next], rest: Array(rest.dropFirst()), key: key) : false
    }

    private static func cut(_ bytes: [UInt8], member index: Int, of object: Object, emptyInner: String) -> [UInt8] {
        var result = bytes
        let members = object.members
        if members.count == 1 {
            result.replaceSubrange((object.open + 1)..<object.close, with: Array(emptyInner.utf8))
        } else if index > 0 {
            result.removeSubrange(members[index - 1].valueEnd..<members[index].valueEnd)
        } else {
            result.removeSubrange(members[0].keyStart..<members[1].keyStart)
        }
        return result
    }

    // MARK: Rendering

    /// The member that holds `value` under `chain`: `chain[0]: {chain[1]: {... value}}`.
    private static func member(_ chain: [String], _ value: OrderedJSON) -> (key: String, value: OrderedJSON) {
        (chain[0], chain.dropFirst().reversed().reduce(value) { inner, key in .object([(key, inner)]) })
    }

    static func render(key: String, value: OrderedJSON, indent: String, unit: String) -> String {
        quote(key) + ": " + renderValue(value, indent: indent, unit: unit)
    }

    static func renderValue(_ value: OrderedJSON, indent: String, unit: String) -> String {
        switch value {
        case .object(let members) where members.isEmpty:
            return "{}"
        case .object(let members):
            let inner = indent + unit
            return "{\n" + members.map { inner + render(key: $0.0, value: $0.1, indent: inner, unit: unit) }.joined(separator: ",\n") + "\n" + indent + "}"
        default:
            return renderInlineValue(value)
        }
    }

    static func renderInline(key: String, value: OrderedJSON) -> String {
        quote(key) + ": " + renderInlineValue(value)
    }

    static func renderInlineValue(_ value: OrderedJSON) -> String {
        switch value {
        case .string(let text): return quote(text)
        case .bool(let flag): return flag ? "true" : "false"
        case .array(let items): return "[" + items.map(renderInlineValue).joined(separator: ", ") + "]"
        case .object(let members) where members.isEmpty: return "{}"
        case .object(let members): return "{ " + members.map { renderInline(key: $0.0, value: $0.1) }.joined(separator: ", ") + " }"
        }
    }

    static func quote(_ text: String) -> String {
        String(decoding: JSONValue.string(text).encoded(), as: UTF8.self)
    }

    // MARK: Scanning

    /// The object at `path`, or the deepest object that exists on it and how deep that is.
    private static func descend(_ bytes: [UInt8], path: [String]) throws -> (object: Object?, deepest: Object, depth: Int) {
        var index = skipTrivia(bytes, 0)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { throw EditError.notAnObject }
        var current = try parseObject(bytes, index)
        for (depth, key) in path.enumerated() {
            guard let member = current.members.last(where: { $0.key == key }) else { return (nil, current, depth) }
            index = member.valueStart
            guard bytes[index] == UInt8(ascii: "{") else { throw EditError.notAnObjectAt(key) }
            current = try parseObject(bytes, index)
        }
        return (current, current, path.count)
    }

    static func parseObject(_ bytes: [UInt8], _ start: Int) throws -> Object {
        var index = start + 1
        var members: [Member] = []
        while true {
            index = skipTrivia(bytes, index)
            guard index < bytes.count else { throw EditError.malformed(index) }
            switch bytes[index] {
            case UInt8(ascii: "}"):
                return Object(open: start, close: index, members: members)
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "\""):
                let keyStart = index
                let (key, afterKey) = try parseString(bytes, index)
                index = skipTrivia(bytes, afterKey)
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw EditError.malformed(index) }
                let valueStart = skipTrivia(bytes, index + 1)
                let valueEnd = try skipValue(bytes, valueStart)
                members.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))
                index = valueEnd
            default:
                throw EditError.malformed(index)
            }
        }
    }

    private static func parseString(_ bytes: [UInt8], _ start: Int) throws -> (String, Int) {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
            if bytes[index] == UInt8(ascii: "\"") {
                let raw = Data(bytes[start...index])
                guard let text = try? JSONDecoder().decode(String.self, from: raw) else { throw EditError.malformed(start) }
                return (text, index + 1)
            }
            index += 1
        }
        throw EditError.malformed(start)
    }

    private static func skipValue(_ bytes: [UInt8], _ start: Int) throws -> Int {
        guard start < bytes.count else { throw EditError.malformed(start) }
        switch bytes[start] {
        case UInt8(ascii: "{"):
            return try parseObject(bytes, start).close + 1
        case UInt8(ascii: "["):
            var index = start + 1
            while true {
                index = skipTrivia(bytes, index)
                guard index < bytes.count else { throw EditError.malformed(index) }
                if bytes[index] == UInt8(ascii: "]") { return index + 1 }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                index = try skipValue(bytes, index)
            }
        case UInt8(ascii: "\""):
            return try parseString(bytes, start).1
        default:
            var index = start
            while index < bytes.count, !isSpace(bytes[index]), !",}]/".utf8.contains(bytes[index]) { index += 1 }
            guard index > start else { throw EditError.malformed(start) }
            return index
        }
    }

    /// Past whitespace and comments.
    static func skipTrivia(_ bytes: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < bytes.count {
            if isSpace(bytes[index]) { index += 1; continue }
            if bytes[index] == UInt8(ascii: "/"), index + 1 < bytes.count {
                if bytes[index + 1] == UInt8(ascii: "/") {
                    while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                    continue
                }
                if bytes[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) { index += 1 }
                    index += 2
                    continue
                }
            }
            break
        }
        return min(index, bytes.count)
    }

    /// JSON text with comments and trailing commas removed, strings untouched.
    static func strip(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let start = index
                index += 1
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") { index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1 }
                index = min(index + 1, bytes.count)
                out += bytes[start..<index]
                continue
            }
            if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") || bytes[index + 1] == UInt8(ascii: "*") {
                index = skipTrivia(bytes, index)
                out.append(UInt8(ascii: " "))
                continue
            }
            if byte == UInt8(ascii: ",") {
                let next = skipTrivia(bytes, index + 1)
                if next < bytes.count, bytes[next] == UInt8(ascii: "}") || bytes[next] == UInt8(ascii: "]") { index += 1; continue }
            }
            out.append(byte)
            index += 1
        }
        return out
    }

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// The indentation before `position` when it starts its own line after `after`.
    private static func lineIndent(_ bytes: [UInt8], at position: Int, after: Int) -> String? {
        var index = position - 1
        while index > after, bytes[index] == 0x20 || bytes[index] == 0x09 { index -= 1 }
        guard index > after, bytes[index] == 0x0A else { return nil }
        return String(decoding: bytes[(index + 1)..<position], as: UTF8.self)
    }

    /// The leading whitespace of the line `position` is on.
    private static func lineIndentOfLine(_ bytes: [UInt8], containing position: Int) -> String {
        var start = position
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// The file's indent step: the leading whitespace of its first indented line, else 2 spaces.
    private static func indentUnit(_ bytes: [UInt8]) -> String {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                var end = index + 1
                while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
                if end > index + 1, end < bytes.count, bytes[end] != 0x0A { return String(decoding: bytes[(index + 1)..<end], as: UTF8.self) }
            }
            index += 1
        }
        return "  "
    }
}

/// JSON with member order kept, for what Domovy writes into config files.
indirect enum OrderedJSON: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool { a.plain == b.plain }

    /// The same value without order, to compare with what a file holds.
    var plain: JSONValue {
        switch self {
        case .string(let text): .string(text)
        case .bool(let flag): .bool(flag)
        case .array(let items): .array(items.map(\.plain))
        case .object(let members): .object(Dictionary(members.map { ($0.0, $0.1.plain) }, uniquingKeysWith: { _, last in last }))
        }
    }
}
