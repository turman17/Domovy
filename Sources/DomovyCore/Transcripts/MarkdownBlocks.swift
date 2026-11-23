import Foundation

/// Block structure of the markdown agents write: headings, lists, quotes, code, tables and
/// paragraphs. Inline styling (bold, code spans, links) is left in the text for the UI.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `ordinal` is the number of an ordered item, `nil` for a bullet. `depth` 0 is the outermost.
    case listItem(depth: Int, ordinal: Int?, text: String)
    case quote(String)
    case code(language: String?, text: String)
    /// First row is the header when the table had a `---` separator row.
    case table(rows: [[String]], hasHeader: Bool)
    case rule

    /// Splits `text` into blocks. Unclosed code fences run to the end; anything unrecognized is
    /// a paragraph, so no text is ever dropped.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if Self.isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix("|") {
                flushParagraph()
                var rows: [[String]] = []
                var hasHeader = false
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    let cells = Self.cells(row)
                    if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) {
                        hasHeader = rows.count == 1
                    } else {
                        rows.append(cells)
                    }
                    index += 1
                }
                blocks.append(.table(rows: rows, hasHeader: hasHeader))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix(">") else { break }
                    quoted.append(String(row.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if let item = Self.listItem(line) {
                flushParagraph()
                var text = item.text
                index += 1
                // Indented lines that are not items themselves continue the item.
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty, next.hasPrefix(" ") || next.hasPrefix("\t"),
                          Self.listItem(next) == nil, !nextTrimmed.hasPrefix("```") else { break }
                    text += "\n" + nextTrimmed
                    index += 1
                }
                blocks.append(.listItem(depth: item.depth, ordinal: item.ordinal, text: text))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, text: text)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func cells(_ row: String) -> [String] {
        var inner = Substring(row)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> (depth: Int, ordinal: Int?, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(indent.count)
        let depth = width / 2
        if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
            return (depth, nil, String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let dot = afterDigits.first, dot == "." || dot == ")", afterDigits.dropFirst().first == " " else { return nil }
        return (depth, number, String(afterDigits.dropFirst(2)))
    }
}
