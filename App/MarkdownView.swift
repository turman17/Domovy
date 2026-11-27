import DomovyCore
import SwiftUI

/// Agent markdown drawn with native text: headings, lists, quotes, code blocks and tables.
/// Inline bold, italics, code spans and links come from Foundation's markdown parser.
struct MarkdownView: View {
    private let blocks: [MarkdownBlock]

    /// `blocks` are parsed once by the caller (`MarkdownBlock.parse`), not on every redraw.
    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                BlockView(block: blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    /// Words of a transcript search to mark in the text.
    @Environment(\.searchHighlight) private var highlight

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text, highlight))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inline(text, highlight))
        case .listItem(let depth, let ordinal, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal.map { "\($0)." } ?? (depth == 0 ? "\u{2022}" : "\u{25E6}"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(inline(text, highlight))
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(inline(text, highlight))
                    .foregroundStyle(.secondary)
            }
        case .code(let language, let text):
            ScrollView(.horizontal) {
                Text(highlighted(AttributedString(text), highlight))
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize()
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(language.map { "\($0) code: \(text)" } ?? "Code: \(text)")
        case .table(let rows, let hasHeader):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell, highlight))
                                    .fontWeight(hasHeader && index == 0 ? .semibold : nil)
                            }
                        }
                        if hasHeader && index == 0 {
                            Divider().gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
                .padding(10)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

/// Bold, italics, code spans, strikethrough and links; the text as written when it is not
/// valid markdown.
private func inline(_ text: String, _ highlight: SearchQuery? = nil) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    return highlighted((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text), highlight)
}

/// `text` with every match of a transcript search on a tinted background.
func highlighted(_ text: AttributedString, _ query: SearchQuery?) -> AttributedString {
    guard let query else { return text }
    let plain = String(text.characters)
    let ranges = query.matches(in: plain)
    guard !ranges.isEmpty else { return text }
    var result = text
    for range in ranges {
        let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
        let length = plain.distance(from: range.lowerBound, to: range.upperBound)
        let lower = result.characters.index(result.startIndex, offsetBy: start)
        let upper = result.characters.index(lower, offsetBy: length)
        result[lower..<upper].backgroundColor = Color.accentColor.opacity(0.3)
    }
    return result
}

extension EnvironmentValues {
    /// The transcript search whose matches text views mark, if one is showing.
    @Entry var searchHighlight: SearchQuery?
}
