@testable import DomovyCore
import Foundation
import Testing

/// Folders macOS refuses to open surface as a calm Full Disk Access note, not an error or a
/// missing agent. A folder with no permissions stands in for a TCC-protected one.
@Suite("Full Disk Access")
struct FullDiskAccessTests {
    final class Home: Sendable {
        let home: URL

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-fda-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit {
            // Give back the permissions the test took away so the folder can be removed.
            if let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator { chmod(url.path, 0o755) }
            }
            try? FileManager.default.removeItem(at: home)
        }

        func folder(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("warp.sqlite"))
            return url
        }
    }

    static let warpData = "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable"

    @Test func openFolderIsNotBlocked() throws {
        let home = try Home()
        let folder = try home.folder("open")
        #expect(!FullDiskAccess.isBlocked(folder))
        #expect(!FullDiskAccess.isBlocked(folder.appendingPathComponent("missing")))
    }

    @Test func lockedFolderIsBlocked() throws {
        let home = try Home()
        let folder = try home.folder("locked")
        chmod(folder.path, 0)
        #expect(FullDiskAccess.isBlocked(folder))
    }

    @Test func lockedWarpContainerShowsANote() async throws {
        let home = try Home()
        let folder = try home.folder(Self.warpData)
        chmod(folder.path, 0)
        let footprint = try await MeasuredAgentFootprint(kind: .warp, home: home.home).footprint()
        #expect(footprint.categories.count == 1)
        #expect(footprint.categories.first?.note == FullDiskAccess.blockedNote)
        #expect(footprint.categories.first?.disposition == .keep)
    }

    @Test func readableWarpContainerIsMeasured() async throws {
        let home = try Home()
        _ = try home.folder(Self.warpData)
        let footprint = try await MeasuredAgentFootprint(kind: .warp, home: home.home).footprint()
        #expect(footprint.categories.first?.note != FullDiskAccess.blockedNote)
        #expect((footprint.categories.first?.sizeBytes ?? 0) > 0)
    }

    @Test func permissionErrorsGetTheCalmLine() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(FullDiskAccess.isPermissionError(denied))
        #expect(FullDiskAccess.explain(denied, agent: .warp).contains("Full Disk Access"))
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        #expect(FullDiskAccess.isPermissionError(wrapped))
        let other = AdapterError.sessionNotFound("abc")
        #expect(!FullDiskAccess.isPermissionError(other))
        #expect(FullDiskAccess.explain(other, agent: .codex) == other.localizedDescription)
    }
}
