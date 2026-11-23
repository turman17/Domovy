import DomovyCore
import SwiftUI

/// Agent markdown drawn with native text: headings, lists, quotes, code blocks and tables.
/// Inline bold, italics, code spans and links come from Foundation's markdown parser.
struct MarkdownView: View {
    private let blocks: [MarkdownBlock]

    init(_ text: String) {
        blocks = MarkdownBlock.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inline(text))
        case .listItem(let depth, let ordinal, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal.map { "\($0)." } ?? (depth == 0 ? "\u{2022}" : "\u{25E6}"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(inline(text))
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(inline(text))
                    .foregroundStyle(.secondary)
            }
        case .code(let language, let text):
            ScrollView(.horizontal) {
                Text(text)
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
                                Text(inline(cell))
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
private func inline(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
