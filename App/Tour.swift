import AppKit
import DomovyCore
import Observation
import SwiftUI

/// The guided tour: after the first scan, a dimmed window with one part lit at a time and a
/// short caption, from what the agents keep to where the rules live. Shown once, after the
/// welcome sheet; Help > Take the Tour and Settings > General play it again.
@MainActor
@Observable
final class TourController {
    static let shared = TourController()

    enum Step: Int, CaseIterable {
        case footprint, sessions, transcript, actions, disk, connect, settings, summary

        /// The sidebar section the step needs on screen.
        var section: SidebarItem? {
            switch self {
            case .sessions, .transcript, .actions: .sessions
            case .disk: .disk
            case .footprint, .connect, .settings, .summary: nil
            }
        }

        /// What is lit; nothing lit puts the caption in the middle.
        var targets: [TourTarget] {
            switch self {
            case .footprint: [.sidebarFooter]
            case .sessions: [.sessionsList, .searchField]
            case .transcript: [.inspector]
            case .actions: [.sessionActions]
            case .disk: [.diskSafest]
            case .connect, .settings, .summary: []
            }
        }

        /// The lit part the caption sits next to.
        var cardAnchor: TourTarget? {
            self == .sessions ? .searchField : targets.first
        }

        /// Where the caption goes, first side with room wins.
        var cardSides: [CardSide] {
            switch self {
            case .footprint: [.trailingBottom, .above]
            case .sessions: [.below, .leadingTop]
            case .transcript: [.leadingTop, .leadingBottom]
            case .actions: [.leadingBottom, .above]
            case .disk: [.below, .above, .trailingTop]
            case .connect, .settings, .summary: []
            }
        }

        /// Lit when none of `targets` is on screen (no session selected).
        var fallback: [TourTarget] {
            self == .actions ? [.inspector] : []
        }
    }

    /// The step on screen; nil while no tour runs.
    private(set) var step: Step?
    /// Asked for: starts once the main window is open and the first scan has finished.
    private(set) var isPending = false
    private(set) var pendingStep: Step = .footprint
    /// Bumped when a lit view moved, so the overlay measures again.
    private(set) var layoutRevision = 0
    /// Opens Connect Agents, and a sidebar section (set by the main window).
    @ObservationIgnored var openConnect: (() -> Void)?
    @ObservationIgnored var openSection: ((SidebarItem) -> Void)?
    /// The overlay's own view: lit rects are measured in its coordinates.
    @ObservationIgnored weak var overlayView: NSView?
    @ObservationIgnored private var anchors: [TourTarget: WeakView] = [:]
    @ObservationIgnored private var layoutPending = false

    var isRunning: Bool { step != nil }

    /// Where a caption sits against its lit part: beside it (aligned to its top or bottom
    /// edge), below it (aligned to its trailing edge) or above it.
    enum CardSide {
        case trailingBottom, trailingTop, leadingTop, leadingBottom, below, above
    }

    func request(from step: Step = .footprint) {
        guard !isRunning else { return }
        pendingStep = step
        isPending = true
    }

    func start() {
        guard isPending else { return }
        isPending = false
        step = pendingStep
        UserDefaults.standard.set(true, forKey: Self.shownKey)
    }

    func next() {
        guard let step else { return }
        self.step = Step(rawValue: step.rawValue + 1) ?? step
    }

    func back() {
        guard let step else { return }
        self.step = Step(rawValue: step.rawValue - 1) ?? step
    }

    func end() {
        step = nil
        isPending = false
    }

    /// The tour shows once, by the same rule as the welcome sheet.
    static let shownKey = "didShowTour"

    // MARK: Anchors

    func register(_ view: NSView, for target: TourTarget) {
        anchors[target] = WeakView(view: view)
        anchorsMoved()
    }

    func unregister(_ view: NSView, for target: TourTarget) {
        if anchors[target]?.view === view { anchors[target] = nil }
        anchorsMoved()
    }

    func view(for target: TourTarget) -> NSView? {
        guard let view = anchors[target]?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return view
    }

    /// Coalesced: a layout pass moves many views at once.
    func anchorsMoved() {
        guard isRunning, !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.async { [self] in
            layoutPending = false
            layoutRevision += 1
        }
    }
}

/// A part of the window the tour can light.
enum TourTarget: Hashable {
    /// The main window itself, to place the overlay over it.
    case window
    case sidebarFooter, sessionsList, searchField, inspector, sessionActions, diskSafest
}

struct WeakView {
    weak var view: NSView?
}

// MARK: Facts

/// The real numbers the tour shows, read from the last scan.
struct TourFacts {
    var totalBytes: Int64 = 0
    var safeBytes: Int64 = 0
    var topAgent: AgentKind?
    var topAgentBytes: Int64 = 0
    var topAgentSessions = 0
    var staleSessions = 0
    var liveSessions = 0

    static let staleDays = 30

    @MainActor
    init(library: SessionLibrary, now: Date = Date()) {
        totalBytes = library.totalFootprintBytes
        safeBytes = library.safeFootprintBytes
        if let top = library.footprintByAgent.max(by: { $0.bytes < $1.bytes }), top.bytes > 0 {
            topAgent = top.agent
            topAgentBytes = top.bytes
            topAgentSessions = library.count(for: top.agent)
        }
        let cutoff = now.addingTimeInterval(-Double(Self.staleDays) * 86_400)
        staleSessions = library.sessions.filter { $0.status != .live && !$0.isArchived && $0.lastActive < cutoff }.count
        liveSessions = library.liveSessions.count
    }

    init() {}

    var footprintTitle: String {
        totalBytes > 0 ? "Your AI agents keep \(Self.size(totalBytes)) on this Mac" : "Domovy found no agent folders yet"
    }

    var footprintDetail: String {
        guard totalBytes > 0 else {
            return "When you use Claude Code, Codex, Cursor or another agent Domovy knows, its sessions and caches show up here."
        }
        var lines: [String] = []
        if let topAgent {
            let sessions = topAgentSessions > 0 ? " in \(Self.count(topAgentSessions, "session"))" : ""
            lines.append("\(topAgent.displayName) alone: \(Self.size(topAgentBytes))\(sessions).")
        }
        if safeBytes > 0 {
            lines.append("\(Self.size(safeBytes)) of it is safe to remove: caches and leftovers the agents do not need to run.")
        }
        if staleSessions > 0 {
            lines.append("\(Self.count(staleSessions, "session")) \(staleSessions == 1 ? "has" : "have") not been opened in \(Self.staleDays) days.")
        }
        if liveSessions > 0 {
            lines.append("\(Self.count(liveSessions, "session")) \(liveSessions == 1 ? "is" : "are") live right now; Domovy leaves \(liveSessions == 1 ? "it" : "them") alone.")
        }
        return lines.joined(separator: " ")
    }

    var summaryTitle: String {
        safeBytes > 0 ? "You can free \(Self.size(safeBytes)) now" : "Nothing needs clearing right now"
    }

    static func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }

    static func count(_ n: Int, _ noun: String) -> String { "\(n.formatted()) \(n == 1 ? noun : noun + "s")" }
}

// MARK: Anchor views

extension View {
    /// Marks this view as a part the tour can light. A nil target marks nothing.
    func tourAnchor(_ target: TourTarget?) -> some View {
        background { if let target { TourAnchor(target: target) } }
    }
}

private struct TourAnchor: NSViewRepresentable {
    let target: TourTarget

    func makeNSView(context: Context) -> AnchorView { AnchorView(target: target) }
    func updateNSView(_ view: AnchorView, context: Context) {}
}

/// Reports where its SwiftUI view is, in window coordinates; never takes clicks.
private final class AnchorView: NSView {
    let target: TourTarget

    init(target: TourTarget) {
        self.target = target
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scrollObserver: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if window == nil {
            TourController.shared.unregister(self, for: target)
        } else {
            TourController.shared.register(self, for: target)
            // Scrolling moves the view without a layout pass of its own.
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in
                    MainActor.assumeIsolated { TourController.shared.anchorsMoved() }
                }
            }
        }
    }

    override func layout() {
        super.layout()
        TourController.shared.anchorsMoved()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        TourController.shared.anchorsMoved()
    }
}

// MARK: Host

/// On the main window: starts a requested tour once the first scan is done, keeps the
/// window on the section each step needs, and shows the overlay above it.
struct TourHost: ViewModifier {
    let library: SessionLibrary
    let onConnect: () -> Void

    @State private var tour = TourController.shared
    @State private var presenter = TourPresenter()

    private var isReady: Bool {
        tour.isPending && library.lastScan != nil && !library.isLoading
    }

    func body(content: Content) -> some View {
        content
            .tourAnchor(.window)
            .onChange(of: isReady, initial: true) { _, ready in
                guard ready else { return }
                tour.openConnect = onConnect
                tour.openSection = { [library] in library.requestedSection = $0 }
                tour.start()
            }
            .onChange(of: tour.step) { _, step in
                guard let step else {
                    presenter.close()
                    return
                }
                if let section = step.section, library.requestedSection != section {
                    library.requestedSection = section
                }
                if step == .disk, let agent = TourHost.safestAgent(library) {
                    library.requestedDiskAnchor = agent.rawValue
                }
                if let window = tour.view(for: .window)?.window {
                    presenter.show(over: window, content: TourOverlay(facts: TourFacts(library: library)))
                }
            }
            .task(id: tour.step) {
                // A section switch, the Disk scroll and sections loading above move views
                // without resizing them: measure again while the window settles.
                guard tour.step?.section != nil else { return }
                for delay in [300, 700, 1500, 3000] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled else { return }
                    tour.anchorsMoved()
                }
            }
    }

    /// The agent whose removable bytes are largest, for the Disk step.
    static func safestAgent(_ library: SessionLibrary) -> AgentKind? {
        library.footprints
            .filter { !$0.agent.isModelStore && $0.bytes(.safe) > 0 }
            .max { $0.bytes(.safe) < $1.bytes(.safe) }?
            .agent
    }
}

/// Help > Take the Tour and Settings > General: the main window, then the tour.
@MainActor
enum TakeTour {
    static func start() {
        MainWindow.open()
        TourController.shared.request()
    }
}

extension AppEnvironment {
    /// Debug builds: `DOMOVY_TOUR=disk` (a step name) starts the tour on that step after
    /// the first scan, even against a dev home, for window captures.
    static var startTourStep: TourController.Step? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["DOMOVY_TOUR"] else { return nil }
        return TourController.Step.allCases.first { "\($0)" == raw } ?? .footprint
        #else
        return nil
        #endif
    }
}
