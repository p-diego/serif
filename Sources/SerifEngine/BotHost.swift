import Foundation
import SerifCore
import SwiftTerm

public protocol BotHostDelegate: AnyObject {          // all calls on the engine queue
    func botHost(_ host: BotHost, output data: Data, seq: Int)
    func botHost(_ host: BotHost, screen signals: Set<ScreenSignal>)    // edge-triggered: only newly appeared signals
    func botHostStarted(_ host: BotHost)
    func botHost(_ host: BotHost, exited code: Int32?, ranFor: TimeInterval)
}

/// Crash-restart delay: 2 s doubling up to 300 s; a run of 60 s or more resets it.
public struct Backoff {
    private var next: TimeInterval = 2
    public init() {}
    public mutating func nextDelay(ranFor: TimeInterval) -> TimeInterval {
        if ranFor >= 60 { next = 2 }
        defer { next = min(next * 2, 300) }
        return next
    }
}

/// Runs one real `claude` TUI inside a PTY, mirrors its output into a headless terminal (to read the
/// screen and answer terminal queries) and into a replay buffer. Every method and delegate call is
/// on `queue` (SwiftTerm's LocalProcess is given the same queue).
public final class BotHost {
    public static let size = (cols: 120, rows: 40)
    static let replayLimit = 1 << 20

    public let botId: UUID
    private let queue: DispatchQueue
    private weak var delegate: BotHostDelegate?
    private var process: LocalProcess?
    private var terminal: Terminal?
    private var bridge: Bridge?
    private var startedAt = Date()
    private var killTimer: DispatchWorkItem?
    private var checkTimer: DispatchWorkItem?
    private var firstUncheckedOutput: Date?
    private var currentSize = (cols: BotHost.size.cols, rows: BotHost.size.rows)
    private var stopCallbacks: [() -> Void] = []
    private var previousSignals: Set<ScreenSignal> = []
    private var ring = Data()
    /// `seq` counts output bytes over the host's life, across restarts (the app drops anything at or below the last seq it
    /// saw); `replay()` uses the same numbering.
    private var seq = 0

    public private(set) var isRunning = false

    public init(botId: UUID, queue: DispatchQueue, delegate: BotHostDelegate) {
        self.botId = botId
        self.queue = queue
        self.delegate = delegate
    }

    public func start(_ plan: LaunchPlan) {
        guard !isRunning else { return }
        ring = Data(); previousSignals = []
        let bridge = Bridge(host: self)
        let terminal = Terminal(delegate: bridge, options: TerminalOptions(cols: currentSize.cols, rows: currentSize.rows))
        let process = LocalProcess(delegate: bridge, dispatchQueue: queue)
        self.bridge = bridge; self.terminal = terminal; self.process = process
        startedAt = Date()
        // A child inherits its parent thread's signal mask, and GCD worker threads block signals: spawn with an
        // empty mask, or the bot would never see SIGTERM.
        var empty = sigset_t(), saved = sigset_t()
        sigemptyset(&empty)
        pthread_sigmask(SIG_SETMASK, &empty, &saved)
        process.startProcess(executable: plan.executable, args: plan.args,
                             environment: plan.environment.map { "\($0.key)=\($0.value)" },
                             execName: nil, currentDirectory: plan.cwd)
        pthread_sigmask(SIG_SETMASK, &saved, nil)
        guard process.running, process.shellPid > 0 else {
            // forkpty failed: report it as an immediate exit, never as started.
            self.process = nil
            queue.async { [weak self] in
                guard let self, !self.isRunning else { return }
                self.delegate?.botHost(self, exited: nil, ranFor: 0)
            }
            return
        }
        isRunning = true
        delegate?.botHostStarted(self)
    }

    /// SIGTERM, then SIGKILL after 3 s; `then` runs once the process has exited (at once if not running).
    public func stop(then: @escaping () -> Void) {
        guard isRunning, let process else { then(); return }
        stopCallbacks.append(then)
        guard killTimer == nil else { return }
        let pid = process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        let item = DispatchWorkItem { [weak self] in
            guard self?.isRunning == true else { return }
            kill(-pid, SIGKILL) // the child is a session leader after forkpty: kill its whole group
            kill(pid, SIGKILL)
        }
        killTimer = item
        queue.asyncAfter(deadline: .now() + 3, execute: item)
    }

    public func write(_ bytes: [UInt8]) {
        guard isRunning else { return }
        process?.send(data: bytes[...])
    }

    public func typeMessage(_ text: String) {
        write(Array("\u{1B}[200~".utf8) + Array(text.utf8) + Array("\u{1B}[201~".utf8) + [0x0D])
    }

    public func pressEscape() { write([0x1B]) }

    public func resize(cols: Int, rows: Int) {
        let cols = min(max(cols, 1), 1000), rows = min(max(rows, 1), 1000)
        currentSize = (cols, rows)
        guard let process, isRunning else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &ws)
        terminal?.resize(cols: cols, rows: rows)
    }

    public func replay() -> (data: Data, seq: Int) { (Data(ring), seq) }

    public var screenText: String {
        guard let terminal else { return "" }
        return (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
            .joined(separator: "\n")
    }

    // MARK: Called by the bridge, on `queue`

    fileprivate func received(_ slice: ArraySlice<UInt8>) {
        let data = Data(slice)
        seq += data.count
        ring.append(data)
        // removeSubrange (unlike removeFirst) really frees the storage, so memory stays flat.
        if ring.count > Self.replayLimit { ring.removeSubrange(ring.startIndex ..< ring.startIndex + (ring.count - Self.replayLimit)) }
        terminal?.feed(buffer: slice)
        delegate?.botHost(self, output: data, seq: seq)
        // Trailing 100 ms debounce, but never wait more than 300 ms since the first unchecked output.
        let first = firstUncheckedOutput ?? Date()
        firstUncheckedOutput = first
        checkTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkScreen() }
        checkTimer = item
        queue.asyncAfter(deadline: .now() + max(0, min(0.1, 0.3 - Date().timeIntervalSince(first))), execute: item)
    }

    private func checkScreen() {
        firstUncheckedOutput = nil
        guard isRunning else { return }
        let now = screenSignals(in: screenText)
        let fresh = now.subtracting(previousSignals)
        previousSignals = now
        if !fresh.isEmpty { delegate?.botHost(self, screen: fresh) }
    }

    fileprivate func terminated(_ code: Int32?) {
        isRunning = false
        killTimer?.cancel(); killTimer = nil
        checkTimer?.cancel(); checkTimer = nil
        // `process` is kept until the next start() so late PTY bytes are still handled.
        firstUncheckedOutput = nil
        let callbacks = stopCallbacks
        stopCallbacks = []
        delegate?.botHost(self, exited: code, ranFor: Date().timeIntervalSince(startedAt))
        callbacks.forEach { $0() }
    }

    deinit {
        if isRunning, let pid = process?.shellPid, pid > 0 { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
    }

    fileprivate func answer(_ data: ArraySlice<UInt8>) { write(Array(data)) }

    /// Adapter for SwiftTerm's two delegate protocols (they would otherwise leak into BotHost's API).
    private final class Bridge: LocalProcessDelegate, TerminalDelegate {
        weak var host: BotHost?
        init(host: BotHost) { self.host = host }
        // SwiftTerm hands over the raw wait status: decode it (exit code, or 128+signal).
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            host?.terminated(exitCode.map { ($0 & 0x7f) == 0 ? ($0 >> 8) & 0xff : 128 + ($0 & 0x7f) })
        }
        func dataReceived(slice: ArraySlice<UInt8>) { host?.received(slice) }
        func getWindowSize() -> winsize {
            host.map { winsize(ws_row: UInt16($0.currentSize.rows), ws_col: UInt16($0.currentSize.cols), ws_xpixel: 0, ws_ypixel: 0) }
                ?? winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        }
        func send(source: Terminal, data: ArraySlice<UInt8>) { host?.answer(data) }
    }
}
