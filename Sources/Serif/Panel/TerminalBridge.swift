import SwiftUI
import AppKit
import SwiftTerm
import SerifCore

/// PTY size as the engine knows it; the preview lays its screen out with the same grid.
struct PTYSize: Equatable { var cols: Int, rows: Int }

/// One shared connection to a bot's terminal: attaches when the first view (preview or big) needs it, detaches when
/// the last one goes, and fans the output out to every attached view.
@MainActor @Observable
final class TerminalSession {
    let botId: UUID
    /// ponytail: starts at the engine's default (BotHost.size) and follows the big view; after an app restart it can
    /// differ from the real PTY until the big view opens. Upgrade: have the engine report its size on attach.
    private(set) var ptySize = PTYSize(cols: 120, rows: 40)

    @ObservationIgnored private unowned let client: EngineClient
    @ObservationIgnored private let views = NSHashTable<TerminalView>.weakObjects()
    @ObservationIgnored private var buffer = Data()      // replay plus everything since, capped
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var ready = false        // replay received
    @ObservationIgnored private var early: [(seq: Int, data: Data)] = []    // pushes that beat the replay response
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    private static let cap = 1 << 20

    init(botId: UUID, client: EngineClient) { self.botId = botId; self.client = client }

    func add(_ view: TerminalView) {
        views.add(view)
        if ready { feed(buffer, to: [view]) }
        if !attached { attach() }
    }

    func remove(_ view: TerminalView) {
        views.remove(view)
        guard views.count == 0 else { return }
        retry?.cancel(); retry = nil; failures = 0
        guard attached else { return }
        attached = false; ready = false; buffer = Data(); early = []
        let client = client, id = botId
        Task { try? await client.detachTerminal(bot: id) }
    }

    /// Called when the engine connection comes back: the old attachment is gone.
    func reconnected() {
        attached = false
        if views.count > 0 { attach() }
    }

    /// The bot's state changed: a view that could not attach earlier (bot not running yet) tries again now.
    func nudge() {
        if views.count > 0, !attached { attach() }
    }

    func output(seq: Int, data: Data) {
        guard attached else { return }
        guard ready else { early.append((seq, data)); return }
        guard seq > lastSeq else { return }    // already in the replay
        lastSeq = seq
        append(data)
    }

    func input(_ data: Data) {
        let client = client, id = botId
        Task { try? await client.terminalInput(bot: id, data: data) }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        ptySize = PTYSize(cols: cols, rows: rows)
        let client = client, id = botId
        Task { try? await client.resizeTerminal(bot: id, cols: cols, rows: rows) }
    }

    private func attach() {
        attached = true; ready = false; early = []
        Task {
            guard case .terminal(let seq, let data)? = try? await client.attachTerminal(bot: botId) else {
                guard attached else { return }
                attached = false
                // Retry with a growing pause (1 s up to 10 s); a state change nudges sooner.
                failures += 1
                let delay = min(10, 1 << min(failures - 1, 4))
                retry?.cancel()
                retry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    if !Task.isCancelled { self?.nudge() }
                }
                return
            }
            guard attached else { return }    // detached while waiting
            failures = 0
            buffer = data; lastSeq = seq; ready = true
            let all = views.allObjects
            feed(Data([0x1B, 0x63]), to: all)    // RIS: a reattach starts from a clean screen
            feed(data, to: all)
            for e in early where e.seq > seq { lastSeq = e.seq; append(e.data) }
            early = []
        }
    }

    private func append(_ data: Data) {
        buffer.append(data)
        // ponytail: the cut can land inside an escape sequence for views that join later; the TUI repaints on its own.
        if buffer.count > Self.cap { buffer = buffer.suffix(Self.cap) }
        feed(data, to: views.allObjects)
    }

    private func feed(_ data: Data, to targets: [TerminalView]) {
        let bytes = [UInt8](data)[...]
        for view in targets { view.feed(byteArray: bytes) }
    }
}

/// Wires one TerminalView to a session. The preview ignores keys and never resizes the PTY.
final class TerminalBridge: NSObject, TerminalViewDelegate {
    let session: TerminalSession
    let interactive: Bool
    var running = true    // keystrokes to a stopped bot would vanish: ignore them
    private var resizeTask: Task<Void, Never>?

    init(session: TerminalSession, interactive: Bool) { self.session = session; self.interactive = interactive }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard interactive, running else { return }
        let data = Data(data)
        MainActor.assumeIsolated { session.input(data) }    // the delegate is called on the main thread; keeps key order
    }

    func cancelResize() { resizeTask?.cancel() }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard interactive else { return }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            if !Task.isCancelled { session.resize(cols: newCols, rows: newRows) }
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if interactive, let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private func style(_ view: TerminalView, size: CGFloat) {
    view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    view.nativeBackgroundColor = NSColor(Theme.pane)
    view.nativeForegroundColor = NSColor(Theme.text)
}

/// The full interactive terminal; reports its size to the PTY.
struct BigTerminal: NSViewRepresentable {
    let session: TerminalSession
    let running: Bool

    func makeCoordinator() -> TerminalBridge { TerminalBridge(session: session, interactive: true) }

    func makeNSView(context: Context) -> TerminalView {
        let view = BigTerminalView(frame: .zero)
        style(view, size: 13)
        view.terminalDelegate = context.coordinator
        context.coordinator.running = running
        session.add(view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) { context.coordinator.running = running }

    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalBridge) {
        coordinator.cancelResize()
        MainActor.assumeIsolated { coordinator.session.remove(view) }
    }
}

/// Takes keyboard focus as soon as it is in a window.
private final class BigTerminalView: TerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DispatchQueue.main.async { window.makeFirstResponder(self) } }
    }
}

/// Container that shows a terminal laid out at its natural size, scaled down to the width it is given.
final class PreviewHost: NSView {
    let terminal = TerminalView(frame: .zero)
    private(set) var natural = NSSize(width: 100, height: 100)

    override init(frame: NSRect) { super.init(frame: frame); addSubview(terminal) }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ size: PTYSize) {
        terminal.getTerminal().resize(cols: size.cols, rows: size.rows)
        natural = terminal.getOptimalFrameSize().size
        terminal.frame = NSRect(origin: .zero, size: natural)
        bounds = NSRect(origin: .zero, size: natural)
    }

    // Keep the bounds at the natural size so AppKit scales the terminal to whatever frame SwiftUI gives.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        bounds = NSRect(origin: .zero, size: natural)
    }
}

/// Read-only live mirror at 7 pt; does not touch the PTY size.
struct PreviewTerminal: NSViewRepresentable {
    let session: TerminalSession

    func makeCoordinator() -> TerminalBridge { TerminalBridge(session: session, interactive: false) }

    func makeNSView(context: Context) -> PreviewHost {
        let host = PreviewHost(frame: .zero)
        style(host.terminal, size: 7)
        host.terminal.terminalDelegate = context.coordinator
        host.apply(session.ptySize)
        session.add(host.terminal)
        return host
    }

    func updateNSView(_ host: PreviewHost, context: Context) {
        if host.terminal.getTerminal().cols != session.ptySize.cols || host.terminal.getTerminal().rows != session.ptySize.rows {
            host.apply(session.ptySize)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: PreviewHost, context: Context) -> CGSize? {
        let width = proposal.width ?? 288
        return CGSize(width: width, height: width * host.natural.height / max(host.natural.width, 1))
    }

    static func dismantleNSView(_ host: PreviewHost, coordinator: TerminalBridge) {
        MainActor.assumeIsolated { coordinator.session.remove(host.terminal) }
    }
}

extension BotState {
    /// False when there is no process to talk to.
    var hasProcess: Bool { switch self { case .stopped, .crashed: false; default: true } }
    /// When a crashed bot is relaunched by the engine, if it is.
    var retryAt: Date? { if case .crashed(_, let at) = self { at } else { nil } }
}

/// Dims a terminal of a bot that is not running and says why.
struct StoppedOverlay: View {
    let state: BotState
    var radius: CGFloat = 0

    var body: some View {
        if !state.hasProcess {
            ZStack {
                Color.black.opacity(0.55)
                if let text = stateText(state) {
                    Text(text).font(.system(size: Theme.Size.label)).foregroundStyle(.white).multilineTextAlignment(.center).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
        }
    }
}
