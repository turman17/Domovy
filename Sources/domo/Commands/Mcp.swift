import ArgumentParser
import DomovyCore
import Foundation

struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run Domovy's MCP server over stdio, for AI agents.",
        discussion: """
        Agents start this themselves once registered (`domo install`); `domo` with piped stdin does the same. It lists sessions and disk use, \
        plans deletes and archives, and runs a plan only with the token the plan returned. \
        Uses --root, else DOMOVY_ROOT, else your home.
        """
    )

    @OptionGroup var options: RootOptions

    func run() async throws {
        let context = options.root == nil
            ? DomovyContext.fromEnvironment()
            : DomovyContext(home: options.home, isCustomHome: true)
        await Self.serve(context)
    }

    static func serve(_ context: DomovyContext) async {
        await MCPServer(tools: DomovyTools(context: context)).run()
    }
}
