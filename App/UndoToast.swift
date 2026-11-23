import SwiftUI

/// "Moved “X” (86 MB) to the Trash.  Undo ⌘Z". Sits at the bottom of the sessions list.
struct UndoToast: View {
    let toast: Toast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(toast.message)
                .lineLimit(1)
            if toast.undoEntry != nil {
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .fontWeight(.medium)
                Text("⌘Z")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityLabel(toast.message)
    }
}
