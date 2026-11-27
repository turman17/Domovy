import DomovyCore
import SwiftUI

/// Small monochrome agent mark: two letters in a bordered square. Never a vendor logo.
struct AgentGlyph: View {
    let agent: AgentKind

    private var letters: String {
        switch agent {
        case .claudeCode: "CC"
        case .claudeDesktop: "CD"
        case .codex: "Cx"
        case .cursor: "Cu"
        case .gemini: "Ge"
        case .antigravity: "AG"
        case .openCode: "OC"
        case .copilot: "CP"
        case .zed: "Ze"
        case .vsCodeChat: "VS"
        case .geminiCodeAssist: "GA"
        case .qwen: "Qw"
        case .kimi: "Ki"
        case .rooCode: "Ro"
        case .crush: "Cr"
        case .cline: "Cl"
        case .kilo: "Kl"
        case .continueDev: "Co"
        case .auggie: "Au"
        case .factoryDroid: "FD"
        case .aider: "Ai"
        case .kiro: "Kr"
        case .goose: "Go"
        case .grok: "Gk"
        case .amazonQ: "AQ"
        case .windsurf: "Ws"
        case .trae: "Tr"
        case .warp: "Wp"
        case .amp: "Am"
        case .junie: "Ju"
        case .iflow: "iF"
        case .herdr: "He"
        case .ollama: "Ol"
        case .lmStudio: "LM"
        case .huggingFace: "HF"
        }
    }

    var body: some View {
        Text(letters)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .frame(width: 16, height: 16)
            .foregroundStyle(.secondary)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
            .accessibilityLabel(agent.displayName)
    }
}

/// Status is never color alone: symbol + word. Expiring uses the accent, live and idle are gray.
struct StatusLabel: View {
    let session: Session

    var body: some View {
        switch session.status {
        case .live:
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Live: an agent is using this session")
        case .idle:
            Label("Idle", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .archived:
            Label("Archived", systemImage: "archivebox")
                .foregroundStyle(.secondary)
        case .expiring:
            let days = session.daysUntilExpiry ?? 0
            // No date for a count-based rule (Antigravity's 500 conversations): the note says why.
            let text = session.expiresAt == nil ? "At risk" : days == 0 ? "Next sweep" : "\(days) \(days == 1 ? "day" : "days")"
            Label(text, systemImage: "clock")
                .foregroundStyle(.tint)
                .help(session.retentionNote ?? session.expiresAt.map { "\(session.agent.displayName) will delete this session around \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                .accessibilityLabel(session.expiresAt == nil ? "At risk: \(session.retentionNote ?? "the agent may delete it soon")" : days == 0 ? "Expiring at the next sweep" : "Expiring in \(days) days")
        }
    }
}

/// `key.fill` in the accent with the count, when the secret scan flagged the session.
struct SecretMarker: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "key.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tint)
                .help("\(count) possible \(count == 1 ? "secret" : "secrets") found by the secret scan")
                .accessibilityLabel("\(count) possible \(count == 1 ? "secret" : "secrets")")
        }
    }
}

/// Small "Experimental" tag for an agent whose adapter is not yet verified on a real install.
struct ExperimentalBadge: View {
    var body: some View {
        Image(systemName: "flask")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(AgentKind.experimentalNote)
            .accessibilityLabel("Experimental")
            .accessibilityHint(AgentKind.experimentalNote)
    }
}

/// Proportional bar, one segment per agent. Accent shades, then gray for the rest.
struct BreakdownBar: View {
    let segments: [(name: String, bytes: Int64)]
    var height: CGFloat = 6

    private var total: Int64 { max(1, segments.reduce(0) { $0 + $1.bytes }) }

    static func color(at index: Int) -> Color {
        let shades: [Color] = [.accentColor, .accentColor.opacity(0.6), .accentColor.opacity(0.85), .accentColor.opacity(0.4)]
        return index < shades.count ? shades[index] : Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let fraction = CGFloat(segment.bytes) / CGFloat(total)
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(Self.color(at: index))
                        .frame(width: max(2, (proxy.size.width - CGFloat(segments.count - 1) * 2) * fraction))
                }
            }
        }
        .frame(height: height)
        .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: height / 2))
        .accessibilityElement()
        .accessibilityLabel(segments.map { "\($0.name) \($0.bytes.formatted(.byteCount(style: .file)))" }.joined(separator: ", "))
    }
}

/// Human readable size with exact bytes in the tooltip, monospaced digits.
struct SizeText: View {
    let bytes: Int64

    var body: some View {
        // The formatter says "Zero kB" for nothing; Finder-style "0 bytes" reads calmer.
        Text(bytes == 0 ? "0 bytes" : bytes.formatted(.byteCount(style: .file)))
            .monospacedDigit()
            .help("\(bytes.formatted()) bytes")
    }
}

/// Relative date with the absolute one in the tooltip.
struct RelativeDateText: View {
    let date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named))
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }
}

/// Path of `url` relative to `root`, or the full path when it is elsewhere.
func relativePath(_ url: URL, under root: URL) -> String {
    let base = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
}

/// Paces work that follows the selection or the search field, called at the start of a
/// `.task(id:)`. The first change goes at once; changes that come quickly after one another
/// (an arrow key held down, typing) wait until they rest, so only the last one is done.
@MainActor
final class LoadPace {
    private var last: ContinuousClock.Instant?
    private let delay: Duration

    init(delay: Duration = .milliseconds(120)) {
        self.delay = delay
    }

    /// False when the task was cancelled while waiting: the input moved on.
    func wait() async -> Bool {
        let now = ContinuousClock.now
        defer { last = now }
        if let last, now - last < .milliseconds(250) {
            try? await Task.sleep(for: delay)
        }
        return !Task.isCancelled
    }
}
