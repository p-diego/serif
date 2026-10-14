import Foundation
import SerifCore

/// A Codex app-server of Serif's (spec §4): the `codex app-server` process, the WebSocket to it with its secret, and
/// JSON-RPC over it. Every callback and method runs on `queue`.
final class CodexServer {
    /// Why a request failed: Codex answered with an error (`fromCodex`), or the server went away; `neverSent` when the
    /// request never left (Codex cannot have taken it).
    struct Failure: Error { let message: String; let fromCodex: Bool; var neverSent = false }

    /// How to start it: `args` gets the port, which can change if one was taken.
    struct Launch {
        let executable: String
        let args: (Int) -> [String]
        let environment: [String: String]
        let cwd: String
        let token: String
        let log: URL        // Codex's own output, for a look after a failure
        /// Holds the running process's pid and its secret's hash ("<pid> <hash>"), so an engine that died without stopping it
        /// stops it at its next start, and only it.
        var pidFile: URL? = nil
    }

    let queue: DispatchQueue
    /// Notifications and server requests, in arrival order.
    var onMessage: ((CodexMessage) -> Void)?
    /// The process ended by itself after `start` succeeded (never after `stop`).
    var onExit: ((Int32) -> Void)?
    private(set) var port = 0

    private let session = URLSession(configuration: .ephemeral)
    private(set) var launch: Launch?
    private var process: Process?
    private var webSocket: URLSessionWebSocketTask?
    private var starting: ((Failure?) -> Void)?
    private var spawns = 0
    private var nextId = 1
    private var waiting: [Int: (Result<JSONValue, Failure>) -> Void] = [:]
    private var stopCallbacks: [() -> Void] = []
    private var killTimer: DispatchWorkItem?
    private var keptAlive: CodexServer?

    init(queue: DispatchQueue) { self.queue = queue }

    var isRunning: Bool { process != nil }

    /// Starts the server on a free port and connects, trying again every 0.2 s until it answers `initialize`; `then`
    /// gets nil then, or Codex's refusal of the handshake (the server is left running for the caller to stop). A server
    /// that exits first (its port was taken meanwhile) starts again on another port, three times at most (spec §8). How
    /// long to wait is the caller's (`stop` ends the attempt).
    func start(_ launch: Launch, then: @escaping (Failure?) -> Void) {
        self.launch = launch
        starting = then
        spawn()
    }

    private func spawn() {
        guard let launch, let port = freePort() else { return started(Failure(message: "No free port for Codex", fromCodex: false)) }
        spawns += 1
        self.port = port
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.executable)
        p.arguments = launch.args(port)
        p.environment = launch.environment
        p.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
        p.standardInput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: launch.log.path, contents: nil)
        let log = FileHandle(forWritingAtPath: launch.log.path) ?? .nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] p in self?.queue.async { self?.exited(p) } }
        // As in BotHost: a child inherits the spawning thread's signal mask, and GCD threads block signals; without an empty
        // mask the server would ignore SIGTERM.
        var empty = sigset_t(), saved = sigset_t()
        sigemptyset(&empty)
        pthread_sigmask(SIG_SETMASK, &empty, &saved)
        defer { pthread_sigmask(SIG_SETMASK, &saved, nil) }
        do { try p.run() } catch { return started(Failure(message: "Cannot run Codex: \(error.localizedDescription)", fromCodex: false)) }
        process = p
        if let file = launch.pidFile {
            try? "\(p.processIdentifier) \(codexTokenHash(launch.token))".write(to: file, atomically: true, encoding: .utf8)
        }
        connect()
    }

    private func connect() {
        guard starting != nil, let launch, let p = process else { return }
        webSocket?.cancel()     // one connection at a time: an earlier attempt's socket must not stay open
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
        request.setValue("Bearer \(launch.token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20      // thread answers and finished turns can be large
        webSocket = task
        task.resume()
        receive(task)
        let hello: JSONValue = ["clientInfo": ["name": "serif", "title": "Serif", "version": .string(SerifVersion.current)],
                                "capabilities": ["experimentalApi": true]]
        self.request("initialize", hello) { [weak self] result in
            guard let self, starting != nil else { return }
            switch result {
            case .success: notify("initialized", [:]); started(nil)
            case let .failure(f) where f.fromCodex: started(f)      // a Codex refusing the handshake: retrying won't help (spec §8)
            // Not listening yet: again shortly, unless this server is gone (a new one connects by itself).
            case .failure: queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in if self?.process === p { self?.connect() } }
            }
        }
    }

    private func started(_ failure: Failure?) {
        guard let then = starting else { return }
        starting = nil
        then(failure)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self, task === webSocket else { return }
                switch result {
                case .success(let frame):
                    switch frame {
                    case .string(let text): handle(Data(text.utf8))
                    case .data(let data): handle(data)
                    @unknown default: break
                    }
                    receive(task)
                case .failure:
                    webSocket = nil
                    failWaiting("Codex closed the connection")
                    // Running and no longer reachable: stopped, so its exit is reported like a crash.
                    if starting == nil, let process, process.isRunning { terminate(process) }
                }
            }
        }
    }

    private func handle(_ data: Data) {
        // ponytail: a frame that is not JSON-RPC is dropped; Codex never sent one in the 12/10 and 13/10 trials.
        guard let message = CodexMessage(data) else { return }
        switch message {
        case let .response(id, result): waiting.removeValue(forKey: id)?(.success(result))
        case let .failure(id, text): waiting.removeValue(forKey: id)?(.failure(Failure(message: text, fromCodex: true)))
        default: onMessage?(message)
        }
    }

    func request(_ method: String, _ params: JSONValue, then: @escaping (Result<JSONValue, Failure>) -> Void) {
        guard let webSocket else { return then(.failure(Failure(message: "Codex is not connected", fromCodex: false, neverSent: true))) }
        let id = nextId
        nextId += 1
        waiting[id] = then
        webSocket.send(.string(codexRequest(id: id, method: method, params: params))) { [weak self] error in
            guard error != nil else { return }
            self?.queue.async { [weak self] in
                self?.waiting.removeValue(forKey: id)?(.failure(Failure(message: "Codex is not reachable", fromCodex: false, neverSent: true)))
            }
        }
    }

    func notify(_ method: String, _ params: JSONValue) {
        webSocket?.send(.string(codexNotification(method: method, params: params))) { _ in }
    }

    /// Answers one of the server's requests (an approval, a question).
    func respond(to id: JSONValue, result: JSONValue) { webSocket?.send(.string(codexResponse(id: id, result: result))) { _ in } }

    /// Answers a request Serif does not handle, so Codex does not wait on it.
    func refuse(_ id: JSONValue, message: String) {
        webSocket?.send(.string(codexErrorResponse(id: id, message: message))) { _ in }
    }

    private func failWaiting(_ message: String) {
        let callbacks = waiting.values
        waiting = [:]
        callbacks.forEach { $0(.failure(Failure(message: message, fromCodex: false))) }
    }

    /// SIGTERM, then SIGKILL after 3 s; `then` runs once the process has exited (at once if it was not running).
    func stop(then: @escaping () -> Void) {
        starting = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        failWaiting("Codex stopped")
        guard let process else { return then() }
        stopCallbacks.append(then)
        keptAlive = self        // until its exit: an owner that lets go of it still gets `then`, and the grace before SIGKILL
        terminate(process)
    }

    /// SIGTERM now, SIGKILL in 3 s if it is still there (once, however often asked).
    private func terminate(_ process: Process) {
        guard killTimer == nil else { return }
        process.terminate()
        let pid = process.processIdentifier
        let item = DispatchWorkItem { kill(pid, SIGKILL) }
        killTimer = item
        queue.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func exited(_ p: Process) {
        guard p === process else { return }
        process = nil
        keptAlive = nil
        // Only while it is still this process's: the next server may have written its own there meanwhile.
        if let file = launch?.pidFile, (try? String(contentsOf: file, encoding: .utf8))?.hasPrefix("\(p.processIdentifier) ") == true {
            try? FileManager.default.removeItem(at: file)
        }
        killTimer?.cancel()
        killTimer = nil
        webSocket?.cancel()
        webSocket = nil
        failWaiting("Codex exited")
        if starting != nil {
            // Gone before answering: its port was probably taken meanwhile (spec §8).
            if spawns < 3 { return spawn() }
            return started(Failure(message: "Codex exited at start (code \(p.terminationStatus))", fromCodex: false))
        }
        let callbacks = stopCallbacks
        stopCallbacks = []
        if callbacks.isEmpty { onExit?(p.terminationStatus) }
        callbacks.forEach { $0() }
    }

    deinit {
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        session.invalidateAndCancel()
    }
}

/// A TCP port free on 127.0.0.1 right now, picked by the system; nil if there is none. Another process can take it before
/// Codex binds it: `CodexServer` then starts it again on another.
func freePort() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
}
