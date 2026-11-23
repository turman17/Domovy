import ArgumentParser
import DomovyCore
import Foundation

struct Du: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show disk use per agent and category.")

    @OptionGroup var options: RootOptions

    func run() async throws {
        var footprints: [Footprint] = []
        do {
            for adapter in await options.installedAdapters() { footprints.append(try await adapter.footprint()) }
        } catch {
            throw Domo.fail(error)
        }
        guard !footprints.isEmpty else {
            print("No agent folders found. All tidy.")
            return
        }
        for (index, footprint) in footprints.enumerated() {
            if index > 0 { print("") }
            print("\(footprint.agent.displayName)  \(footprint.root.path)  \(Format.bytes(footprint.totalBytes))")
            print("")
            let rows = footprint.categories
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .map { [Format.bytes($0.sizeBytes), $0.disposition.rawValue, $0.name, $0.note] }
            print(Format.table(rows, header: ["SIZE", "DISPOSITION", "CATEGORY", "NOTE"], rightAligned: [0]))
        }
        if footprints.count > 1 {
            print("\nTotal: \(Format.bytes(footprints.reduce(0) { $0 + $1.totalBytes }))")
        }
    }
}
