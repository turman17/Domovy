import AppKit
import DomovyCore
import SwiftUI

/// The overlay as the topmost view of the main window's frame view, so it covers the
/// toolbar too, moves and resizes with the window, and is part of the window's own image.
@MainActor
final class TourPresenter {
    private var host: NSHostingView<TourOverlay>?
    private var observer: (any NSObjectProtocol)?

    func show(over window: NSWindow, content: TourOverlay) {
        if let host, host.window === window {
            host.rootView = content
            return
        }
        close()
        guard let frameView = window.contentView?.superview else { return }
        let host = NSHostingView(rootView: content)
        host.frame = frameView.bounds
        host.autoresizingMask = [.width, .height]
        frameView.addSubview(host, positioned: .above, relativeTo: nil)
        window.makeFirstResponder(host)
        TourController.shared.overlayView = host
        self.host = host
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { TourController.shared.end() }
        }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        host?.removeFromSuperview()
        host = nil
    }
}

/// The dimmed window with the lit parts cut out, and the caption card next to them.
struct TourOverlay: View {
    let facts: TourFacts

    @State private var tour = TourController.shared
    @State private var cardSize = CGSize(width: TourCard.width, height: 160)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private static let margin: CGFloat = 16
    private static let inset: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let lit = lit()
            let holes = lit.map(\.rect)
            ZStack(alignment: .topLeading) {
                SpotlightShape(primary: holes.first ?? CGRect(x: proxy.size.width / 2, y: proxy.size.height / 2, width: 0, height: 0),
                               extra: Array(holes.dropFirst()), cornerRadius: 10)
                    .fill(dim, style: FillStyle(eoFill: true))
                    .accessibilityHidden(true)
                ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 3 : 2)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .accessibilityHidden(true)
                }
                if let step = tour.step {
                    let anchor = lit.first { $0.target == step.cardAnchor }?.rect ?? holes.first
                    TourCard(step: step, facts: facts, hasTarget: anchor != nil)
                        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { cardSize = $0 })
                        .offset(cardOrigin(near: anchor, sides: step.cardSides, in: proxy.size))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: tour.step)
    }

    private var dim: Color {
        let base: Double = colorScheme == .dark ? 0.62 : 0.5
        return Color.black.opacity(contrast == .increased ? base + 0.15 : base)
    }

    /// The lit parts of this step, in the overlay's coordinates.
    private func lit() -> [(target: TourTarget, rect: CGRect)] {
        _ = tour.layoutRevision
        guard let step = tour.step else { return [] }
        let found = litParts(step.targets)
        return found.isEmpty ? litParts(step.fallback) : found
    }

    private func litParts(_ targets: [TourTarget]) -> [(target: TourTarget, rect: CGRect)] {
        targets.compactMap { target in
            guard let rect = rect(of: target), rect.width > 4, rect.height > 4 else { return nil }
            // The ring stays inside the window, also for parts at its edge.
            let bounds = tour.overlayView?.bounds.insetBy(dx: 2, dy: 2) ?? .infinite
            return (target, rect.insetBy(dx: -Self.inset, dy: -Self.inset).intersection(bounds))
        }
    }

    /// Where a target is, only the part on screen, in the overlay's (flipped) coordinates.
    private func rect(of target: TourTarget) -> CGRect? {
        guard let overlay = tour.overlayView else { return nil }
        let view: NSView
        if target == .searchField {
            let search = overlay.window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
            guard let field = search?.searchField, field.window === overlay.window else { return nil }
            view = field
        } else {
            guard let anchor = tour.view(for: target), anchor.window === overlay.window else { return nil }
            view = anchor
        }
        // Inside SwiftUI hosts visibleRect can exceed the bounds; keep only the view's own part.
        let visible = view.visibleRect.intersection(view.bounds)
        guard !visible.isEmpty else { return nil }
        return view.convert(visible, to: overlay)
    }

    /// The first side of the lit part with room for the card, else the middle; always
    /// inside the window.
    private func cardOrigin(near rect: CGRect?, sides: [TourController.CardSide], in size: CGSize) -> CGSize {
        let margin = Self.margin, gap: CGFloat = 12, card = cardSize
        let centered = CGSize(width: (size.width - card.width) / 2, height: (size.height - card.height) / 2)
        guard let rect else { return centered }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, margin), size.width - card.width - margin) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, margin), size.height - card.height - margin) }
        for side in sides {
            switch side {
            case .trailingBottom where size.width - rect.maxX >= card.width + gap + margin:
                return CGSize(width: rect.maxX + gap, height: clampY(rect.maxY - card.height))
            case .trailingTop where size.width - rect.maxX >= card.width + gap + margin:
                return CGSize(width: rect.maxX + gap, height: clampY(rect.minY))
            case .leadingTop where rect.minX >= card.width + gap + margin:
                return CGSize(width: rect.minX - gap - card.width, height: clampY(rect.minY))
            case .leadingBottom where rect.minX >= card.width + gap + margin:
                return CGSize(width: rect.minX - gap - card.width, height: clampY(rect.maxY - card.height))
            case .below where size.height - rect.maxY >= card.height + gap + margin:
                return CGSize(width: clampX(rect.maxX - card.width), height: rect.maxY + gap)
            case .above where rect.minY >= card.height + gap + margin:
                return CGSize(width: clampX(rect.minX), height: rect.minY - gap - card.height)
            default: continue
            }
        }
        return centered
    }
}

/// A full rect with rounded holes; the first hole animates between steps.
private struct SpotlightShape: Shape {
    var primary: CGRect
    var extra: [CGRect]
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(primary.minX, primary.minY), AnimatablePair(primary.width, primary.height)) }
        set { primary = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in [primary] + extra where hole.width > 0 && hole.height > 0 {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        }
        return path
    }
}

/// The caption: step count, title, a few plain sentences, and the buttons.
private struct TourCard: View {
    static let width: CGFloat = 360
    static let summaryWidth: CGFloat = 440

    let step: TourController.Step
    let facts: TourFacts
    let hasTarget: Bool

    @State private var tour = TourController.shared
    @AccessibilityFocusState private var titleFocused: Bool

    private static let countedSteps = TourController.Step.allCases.count - 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if step != .summary {
                Text("\(step.rawValue + 1) of \(Self.countedSteps)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label {
                Text(title)
                    .font(step == .footprint || step == .summary ? .title3.weight(.semibold) : .headline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
            }
            .accessibilityFocused($titleFocused)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            buttons
                .padding(.top, 8)
        }
        .padding(16)
        .frame(width: step == .summary ? Self.summaryWidth : Self.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Tour")
        .onExitCommand { tour.end() }
        .onAppear(perform: announce)
        .onChange(of: step) { announce() }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if step == .summary {
                Button("Review Safe Items") {
                    let open = tour.openSection
                    tour.end()
                    open?(.disk)
                }
                .fixedSize()
                Button("Connect Agents\u{2026}") {
                    let open = tour.openConnect
                    tour.end()
                    open?()
                }
                .fixedSize()
                Spacer(minLength: 8)
                Button("Done") { tour.end() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                Button("") { tour.end() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .accessibilityHidden(true)
            } else {
                Button("Skip Tour") { tour.end() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step != .footprint {
                    Button("Back") { tour.back() }
                }
                Button("Next") { tour.next() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// VoiceOver reads each step as it comes, then rests on its title.
    private func announce() {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(title). \(detail)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        titleFocused = true
    }

    private var symbol: String {
        switch step {
        case .footprint: "internaldrive"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .transcript: "text.alignleft"
        case .actions: "arrow.uturn.backward"
        case .disk: "checkmark.circle"
        case .connect: "link"
        case .settings: "gearshape"
        case .summary: "house"
        }
    }

    private var title: String {
        switch step {
        case .footprint: facts.footprintTitle
        case .sessions: "Every session, from every agent"
        case .transcript: "Read before you decide"
        case .actions: "Archive or Delete"
        case .disk: "Safe items come first"
        case .connect: "Ask your agent to tidy up"
        case .settings: "Rules live in Settings"
        case .summary: facts.summaryTitle
        }
    }

    private var detail: String {
        switch step {
        case .footprint:
            facts.footprintDetail
        case .sessions:
            "Search titles and transcripts from the toolbar, and filter by status: live, idle, expiring or archived. The sidebar narrows the list to one agent."
        case .transcript:
            hasTarget
                ? "Select a session to read its transcript here. Space opens it full size."
                : "Select a session to read its transcript in the inspector. Space opens it full size."
        case .actions:
            "Archive compresses a session on disk, and the agent can still resume it. Delete shows every file it moves to the Trash before anything changes. Both can be undone with \u{2318}Z."
        case .disk:
            "Each category says whether it is safe to remove, removable with consequences, or kept because the agent needs it to run. Every cleanup shows its plan first."
        case .connect:
            "Connect Claude Code, Codex and other agents to Domovy, and they can list and tidy sessions for you, through the same plans you approve here. Domovy > Connect Agents\u{2026} sets it up."
        case .settings:
            "Cleanup rules, where removed files go, and which agents Domovy shows are in Settings (\u{2318},). Help > Take the Tour plays this again."
        case .summary:
            "Nothing is removed without a plan you approve, and every step can be undone."
        }
    }
}
