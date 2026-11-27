import AppKit
import DomovyCore
import UniformTypeIdentifiers

/// "Export Transcript…": a save panel with a format choice and the option to keep secrets,
/// then Markdown or a PDF printed from it. Secrets are masked unless the user turns that off.
/// Never writes inside an agent's folder.
@MainActor
enum TranscriptExporter {
    enum Format: Int {
        case markdown
        case pdf

        var fileExtension: String { self == .markdown ? "md" : "pdf" }
        var contentType: UTType { self == .markdown ? UTType(filenameExtension: "md") ?? .plainText : .pdf }
    }

    static func export(_ sessions: [Session], library: SessionLibrary) {
        guard !sessions.isEmpty else { return }
        let panel = NSSavePanel()
        let accessory = Accessory(panel: panel, sessions: sessions)
        panel.title = sessions.count == 1 ? "Export Transcript" : "Export \(sessions.count) Transcripts"
        panel.message = sessions.count == 1 ? "" : "All \(sessions.count) conversations go into one file."
        panel.nameFieldStringValue = TranscriptExport.fileName(for: sessions, extension: Format.markdown.fileExtension)
        panel.allowedContentTypes = [Format.markdown.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.accessoryView = accessory.view
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let format = accessory.format, masks = !accessory.includesSecrets
            withExtendedLifetime(accessory) {}
            if TranscriptExport.isInsideAgentFolder(url, adapters: library.adapters) {
                library.actionError = "Domovy does not save exports inside an agent's own folder, where the agent could read them as its data. Choose another folder."
                return
            }
            Task { await write(sessions, to: url, format: format, masksSecrets: masks, library: library) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private static func write(_ sessions: [Session], to url: URL, format: Format, masksSecrets: Bool, library: SessionLibrary) async {
        do {
            let items = try await TranscriptExport.items(for: sessions, adapters: library.adapters, masksSecrets: masksSecrets,
                                                         findings: library.secretFindings, usage: library.tokenUsage)
            let output = await Task.detached { TranscriptExport.markdown(items, masksSecrets: masksSecrets) }.value
            switch format {
            case .markdown: try Data(output.markdown.utf8).write(to: url, options: .atomic)
            case .pdf: try writePDF(output.markdown, to: url)
            }
            let what = sessions.count == 1 ? "the transcript" : "\(sessions.count) transcripts"
            let masked = output.maskedCount > 0
                ? " Masked \(output.maskedCount) possible \(output.maskedCount == 1 ? "secret" : "secrets")."
                : masksSecrets ? "" : " Secrets were kept as they are."
            library.toast = Toast(message: "Exported \(what) to \(url.lastPathComponent).\(masked)", undo: nil)
        } catch {
            library.actionError = "Domovy could not export \(sessions.count == 1 ? "this transcript" : "these transcripts"): \(error.localizedDescription)"
        }
    }

    /// Prints the Markdown as styled text into a PDF, through AppKit's print path.
    static func writePDF(_ markdown: String, to url: URL) throws {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        text.textStorage?.setAttributedString(styled(markdown))
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.sizeToFit()
        let operation = NSPrintOperation(view: text, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Headings bold, quoted tool lines grey, the rest body text. Black on white: a PDF is
    /// paper, whatever the window's appearance.
    private static func styled(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            var font = body
            var color = NSColor.black
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 2
            if let level = text.firstIndex(where: { $0 != "#" }).map({ text.distance(from: text.startIndex, to: $0) }), level > 0, text.dropFirst(level).hasPrefix(" ") {
                text = String(text.dropFirst(level + 1))
                font = NSFont.boldSystemFont(ofSize: [20, 16, 13, 12][min(level, 4) - 1])
                paragraph.paragraphSpacingBefore = level <= 2 ? 10 : 6
            } else if text.hasPrefix("> ") {
                text = String(text.dropFirst(2))
                color = .darkGray
                font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            } else if text == "---" {
                text = ""
            }
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        return result
    }

    /// Format and secrets controls under the save panel's file browser.
    @MainActor
    final class Accessory: NSObject {
        let view: NSView
        private let panel: NSSavePanel
        private let sessions: [Session]
        private let formatPopup = NSPopUpButton()
        private let secrets = NSButton(checkboxWithTitle: "Include secrets as they are", target: nil, action: nil)
        private let warning = NSTextField(wrappingLabelWithString: "")

        var format: Format { Format(rawValue: formatPopup.indexOfSelectedItem) ?? .markdown }
        var includesSecrets: Bool { secrets.state == .on }

        init(panel: NSSavePanel, sessions: [Session]) {
            self.panel = panel
            self.sessions = sessions
            formatPopup.addItems(withTitles: ["Markdown", "PDF"])
            let label = NSTextField(labelWithString: "Format:")
            let row = NSStackView(views: [label, formatPopup])
            row.orientation = .horizontal
            warning.font = .preferredFont(forTextStyle: .caption1)
            warning.textColor = .secondaryLabelColor
            warning.preferredMaxLayoutWidth = 420
            let stack = NSStackView(views: [row, secrets, warning])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
            view = stack
            super.init()
            formatPopup.target = self
            formatPopup.action = #selector(formatChanged)
            secrets.target = self
            secrets.action = #selector(secretsChanged)
            secrets.setAccessibilityHelp("Off by default: possible API keys, tokens and passwords are replaced by a masked preview.")
            updateWarning()
        }

        @objc private func formatChanged() {
            panel.allowedContentTypes = [format.contentType]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = name + "." + format.fileExtension
        }

        @objc private func secretsChanged() { updateWarning() }

        private func updateWarning() {
            warning.stringValue = includesSecrets
                ? "Careful: the file will hold any API keys, tokens and passwords in the conversation in plain text. Anyone who can read the file can use them."
                : "Possible API keys, tokens and passwords are replaced by a masked preview, like \u{201C}[ghp_\u{2026}0000]\u{201D}."
            warning.textColor = includesSecrets ? .labelColor : .secondaryLabelColor
        }
    }
}
