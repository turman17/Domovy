@testable import DomovyCore
import Testing

@Suite("Display titles")
struct DisplayTitleTests {
    @Test("drops context blocks the agents put before the prompt")
    func contextBlocks() {
        #expect(Session.cleanTitle("<session_context>\nworkspace: orbit-api\n</session_context>\nFix the login redirect") == "Fix the login redirect")
        #expect(Session.cleanTitle("<session_context>x</session_context>\nFirst line\nsecond line") == "First line second line")
        #expect(Session.cleanTitle("<system-reminder>be brief</system-reminder><environment_context>cwd</environment_context> Add tests") == "Add tests")
        #expect(Session.cleanTitle("<user_instructions attr=\"1\">rules</user_instructions>Ship it") == "Ship it")
    }

    @Test("keeps what a command wrapper holds")
    func commandWrapper() {
        #expect(Session.cleanTitle("<command-name>/review</command-name> <command-args>auth</command-args>") == "/review auth")
    }

    @Test("a prompt that was only context has no title")
    func onlyContext() {
        #expect(Session.cleanTitle("<session_context>workspace</session_context>") == nil)
        #expect(Session.cleanTitle("<session_context>never closed") == nil)
        #expect(Session.cleanTitle("   ") == nil)
        #expect(Session.cleanTitle(nil) == nil)
    }

    @Test("leaves tags inside the prompt alone")
    func innerTags() {
        #expect(Session.cleanTitle("Why does the <div> overflow?") == "Why does the <div> overflow?")
    }

    @Test("removes paste placeholders and markdown markers")
    func pasteAndMarkdown() {
        #expect(Session.cleanTitle("<pasted_content id=\"1\"/>") == "Pasted text")
        #expect(Session.cleanTitle("Review **this** `diff` <pasted_content id=\"2\"/>") == "Review this diff")
    }
}
