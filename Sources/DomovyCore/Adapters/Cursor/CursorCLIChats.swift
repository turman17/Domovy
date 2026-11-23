import Foundation

/// Chats of the Cursor agent CLI: one folder per chat, `~/.cursor/chats/<workspace hash>/<chat id>/`
/// (reported on Cursor's forum; not on the verified install). The folder holds a `store.db`;
/// its `meta` table is assumed to keep the chat's name as hex-encoded JSON under key `0`.
/// Domovy reads that name if it can and otherwise shows the chat untitled.
enum CursorCLIChats {
    struct Header {
        let title: String?
        let createdAt: Date?
    }

    static func store(of folder: URL) -> URL {
        folder.appendingPathComponent("store.db")
    }

    static func header(of folder: URL) -> Header {
        guard let reader = SQLiteReader(url: store(of: folder)), reader.columns(of: "meta").isSuperset(of: ["key", "value"]),
              let raw = reader.rows("SELECT CAST(value AS TEXT) FROM meta WHERE key = '0'").first?.first ?? nil else {
            return Header(title: nil, createdAt: nil)
        }
        let data = hexDecoded(raw) ?? Data(raw.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Header(title: nil, createdAt: nil) }
        let name = (object["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return Header(title: name.map { TranscriptMask.TextMasker().mask(String($0.prefix(200))) }, createdAt: CursorHeaders.date(object["createdAt"]))
    }

    /// Newest modification time of anything in the folder.
    static func lastActive(of folder: URL) -> Date {
        let files = [folder] + APFSCompression.regularFiles(at: folder)
        return files.compactMap(FileSystem.modificationDate).max() ?? .distantPast
    }

    private static func hexDecoded(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
