import ArgumentParser
import DomovyCore
import Foundation

struct Du: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show disk use per agent and category.")

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "List the categories `domo clean` can clean up, with their ids.")
    var ids = false

    func run() async throws {
        let result = await FootprintScanner.scan(options.footprintProviders)
        for failure in result.failures { FileHandle.standardError.write(Data("domo: \(failure)\n".utf8)) }
        let footprints = result.footprints
        guard !footprints.isEmpty else {
            print("No agent folders found. All tidy.")
            return
        }
        if ids {
            let rows = footprints.flatMap { footprint in
                footprint.categories.compactMap { category in
                    category.cleanupID.map { [$0.rawValue, Format.bytes(category.sizeBytes), category.disposition.rawValue, footprint.agent.displayName, category.name] }
                }
            }
            guard !rows.isEmpty else {
                print("Nothing to clean up here.")
                return
            }
            print(Format.table(rows, header: ["ID", "SIZE", "DISPOSITION", "AGENT", "CATEGORY"], rightAligned: [1]))
            print("\nPreview one with `domo clean <id> --dry-run`.")
            return
        }
        for (index, footprint) in footprints.enumerated() {
            if index > 0 { print("") }
            print("\(footprint.agent.displayName)  \(footprint.root.path)  \(Format.bytes(footprint.totalBytes))")
            print("")
            let rows = footprint.categories
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .map { [Format.bytes($0.sizeBytes), $0.disposition.rawValue, $0.cleanupID?.rawValue ?? "-", $0.name, $0.note] }
            print(Format.table(rows, header: ["SIZE", "DISPOSITION", "CLEAN ID", "CATEGORY", "NOTE"], rightAligned: [0]))
        }
        if footprints.count > 1 {
            print("\nTotal: \(Format.bytes(footprints.reduce(0) { $0 + $1.totalBytes }))")
        }
    }
}
