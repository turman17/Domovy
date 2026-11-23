import DomovyCore
import SwiftUI

/// What the Disk screen's model rows need: which are ticked, the "unused" threshold, and the
/// per-row Remove action.
struct ModelSelection {
    @Binding var selected: Set<String>
    let unusedDays: Int
    let onRemove: (LocalModel) -> Void

    func binding(for model: LocalModel?) -> Binding<Bool> {
        let ids = $selected
        let id = model?.id
        return Binding(
            get: { id.map { ids.wrappedValue.contains($0) } ?? false },
            set: { isOn in
                guard let id else { return }
                if isOn { ids.wrappedValue.insert(id) } else { ids.wrappedValue.remove(id) }
            }
        )
    }
}

/// "Local models": total, the unused-for-N-days filter, and Remove Selected….
struct LocalModelsHeader: View {
    @Environment(SessionLibrary.self) private var library
    @Binding var unusedDays: Int
    @Binding var selected: Set<String>
    let onRemoveSelected: () -> Void

    static let thresholds = [30, 60, 90, 180]
    /// Scroll target on the Disk screen.
    static let anchor = "local-models"

    private var unused: [LocalModel] { library.unusedModels(days: unusedDays) }
    private var selectedBytes: Int64 {
        library.localModels.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Local models")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SizeText(bytes: library.localModelBytes)
                    .font(.system(.callout, design: .monospaced))
            }
            HStack(spacing: 8) {
                Picker("Unused for", selection: $unusedDays) {
                    ForEach(Self.thresholds, id: \.self) { Text("\($0) days").tag($0) }
                }
                .fixedSize()
                Text(unusedText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Select Unused") { selected = Set(unused.map(\.id)) }
                    .disabled(unused.isEmpty)
                    .help("Ticks every model whose date is older than \(unusedDays) days")
                Button(selected.isEmpty ? "Remove Selected\u{2026}" : "Remove \(selected.count) (\(selectedBytes.formatted(.byteCount(style: .file))))\u{2026}",
                       action: onRemoveSelected)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(selected.isEmpty)
                    .help("Shows exactly what happens to each model first.")
            }
            .font(.callout)
            Text("No store records when a model was last used, so Domovy goes by the date each one knows: when Ollama added it, LM Studio's newest file, the newest Hugging Face download.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var unusedText: String {
        let n = unused.count
        guard n > 0 else { return "Every model is newer than that." }
        let bytes = unused.reduce(Int64(0)) { $0 + $1.sizeBytes }.formatted(.byteCount(style: .file))
        return "\(n) \(n == 1 ? "model" : "models") older than that, \(bytes)"
    }
}

/// "Added 3 months ago", relative with the absolute date in the tooltip, and a clock with
/// words when the model is past the threshold (never color alone).
struct ModelDateLine: View {
    let model: LocalModel
    let unusedDays: Int

    var body: some View {
        HStack(spacing: 8) {
            if let date = model.date {
                (Text("\(model.dateKind.displayName) ") + Text(date, format: .relative(presentation: .named)))
                    .help(date.formatted(date: .abbreviated, time: .shortened))
            }
            if model.isUnused(days: unusedDays) {
                Label("Older than \(unusedDays) days", systemImage: "clock")
                    .foregroundStyle(.tint)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
