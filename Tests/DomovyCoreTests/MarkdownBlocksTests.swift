@testable import DomovyCore
import Testing

@Suite("Markdown blocks")
struct MarkdownBlocksTests {
    @Test("splits headings, paragraphs, lists, quotes and rules")
    func blocks() {
        let text = """
        ## Stocks (Friday close)
        Prices moved.
        Second line.

        - **MRVL:** +20%
          still holding
        - GOOGL
          1. nested one
        > quoted
        ---
        """
        #expect(MarkdownBlock.parse(text) == [
            .heading(level: 2, text: "Stocks (Friday close)"),
            .paragraph("Prices moved.\nSecond line."),
            .listItem(depth: 0, ordinal: nil, text: "**MRVL:** +20%\nstill holding"),
            .listItem(depth: 0, ordinal: nil, text: "GOOGL"),
            .listItem(depth: 1, ordinal: 1, text: "nested one"),
            .quote("quoted"),
            .rule,
        ])
    }

    @Test("keeps code fences verbatim, even unclosed")
    func code() {
        #expect(MarkdownBlock.parse("```swift\nlet a = 1\n\n# not a heading\n```\nafter") == [
            .code(language: "swift", text: "let a = 1\n\n# not a heading"),
            .paragraph("after"),
        ])
        #expect(MarkdownBlock.parse("```\nopen") == [.code(language: nil, text: "open")])
    }

    @Test("reads tables with and without a header row")
    func tables() {
        #expect(MarkdownBlock.parse("| Name | Size |\n|---|---:|\n| a | 1 MB |") == [
            .table(rows: [["Name", "Size"], ["a", "1 MB"]], hasHeader: true),
        ])
        #expect(MarkdownBlock.parse("| a | b |") == [.table(rows: [["a", "b"]], hasHeader: false)])
    }

    @Test("does not mistake ordinary text for markup")
    func plain() {
        #expect(MarkdownBlock.parse("#hashtag and 2024. was a year\n-not a bullet") == [
            .paragraph("#hashtag and 2024. was a year\n-not a bullet"),
        ])
    }
}
