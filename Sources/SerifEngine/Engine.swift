import Foundation
import SerifCore

public enum EngineError: Error { case alreadyRunning }

/// A request the app turned down, sent back as `ResponseBody.error`.
struct Refusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

/// One bot's live state. Only touched on the engine queue.
final class BotRuntime {
    var bot: Bot
    let host: BotHost
    var normalizer = ClaudeNormalizer()
    var tracker = StateTracker()
    var token = UUID().uuidString             // new at every launch: hooks from an older process are dropped
    var outbox: [(text: String, origin: MessageOrigin)] = []   // texts held until SessionStart, or until the open requests close
    var transcriptPath: String?
    var turn: [ChatEvent] = []                // events since the userMessage that opened the current turn
    var flushTimer: DispatchSourceTimer?
    var backoff = Backoff()
    var restart: DispatchWorkItem?
    var trustCheck: DispatchWorkItem?
    var stopping = false
    var resumed = false                       // the running launch used --resume
    var unread = false
    var lastEvent: ChatEventRecord?
    private var preview: String?
    private var previewMessage: String?

    init(bot: Bot, host: BotHost) {
        self.bot = bot
        self.host = host
    }

    /// Keeps the row summary (last event, preview, unread) in step with each appended record.
    func note(_ record: ChatEventRecord) {
        lastEvent = record
        switch record.event {
        case let .assistantText(id, _, delta, _, _):
            if id != previewMessage { previewMessage = id; preview = "" }
            preview? += delta
        case let .assistantTextReplaced(id, text) where id == previewMessage:
            preview = text
        case let .requestOpened(request):
            previewMessage = nil
            let detail = request.input["command"]?.string ?? request.input["questions"]?.array?.first?["question"]?.string
            preview = [request.toolName, detail].compactMap { $0 }.joined(separator: ": ")
        case .turnEnded, .turnFailed, .turnInterrupted:
            unread = true
        default:
            break
        }
    }

    var summary: BotSummary {
        BotSummary(bot: bot, state: tracker.state, unread: unread, lastEvent: lastEvent,
                   preview: preview.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) })
    }
}

/// The engine: keeps every bot's Claude Code alive in a PTY, turns its hooks into chat events, stores them and serves
/// the app. Everything runs on one serial queue; `HookServer.swift` and `AppServer.swift` hold the two socket sides.
public final class Engine {
    let queue = DispatchQueue(label: "com.serif.engine")
    let paths: SerifPaths
    /// Finds the claude executable (serifd: `ClaudeLocator.find`); asked again while Claude Code is not found.
    let locateClaude: @Sendable () -> String?
    /// The last check of Claude Code; nil until a launch or the app's `claudeStatus` asks for one.
    var claudeStatus: ClaudeStatus?
    private var claudeWaiters: [(ClaudeStatus) -> Void] = []
    let hookCommand: String
    let environment: [String: String]
    let store: Store
    let encoder = protocolEncoder()
    let decoder = protocolDecoder()
    var bots: [UUID: BotRuntime] = [:]
    var requests: [UUID: (request: PendingRequest, hook: LineConnection)] = [:]
    var apps: [ObjectIdentifier: (connection: LineConnection, terminals: Set<UUID>)] = [:]
    var stopping = false
    private var servers: [LineServer] = []
    private var lockFD: Int32 = -1

    public init(paths: SerifPaths, locateClaude: @escaping @Sendable () -> String?, hookCommand: String,
                environment: [String: String]) throws {
        self.paths = paths
        self.locateClaude = locateClaude
        self.hookCommand = hookCommand
        self.environment = environment
        store = try Store(paths: paths)
    }

    /// Takes the data folder's lock, opens both sockets and launches every bot that is not archived.
    public func start() throws {
        // O_CLOEXEC: bots must not inherit the lock, or a leftover child process would keep the next engine out.
        let fd = open(paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw EngineError.alreadyRunning }
        do {
            try queue.sync {
                servers.append(try LineServer(path: paths.hookSocket.path, queue: queue) { [weak self] in self?.hookConnected($0) })
                servers.append(try LineServer(path: paths.engineSocket.path, queue: queue) { [weak self] in self?.appConnected($0) })
                lockFD = fd
                for bot in store.bots { launch(addRuntime(bot)) }
            }
        } catch {
            queue.sync { servers.forEach { $0.close() }; servers = [] }
            close(fd)
            throw error
        }
    }

    /// Stops every bot (SIGTERM, SIGKILL after 3 s), closes the sockets and releases the lock; `then` runs on the
    /// engine queue. Safe to call more than once, or on an engine that never started.
    public func shutdown(then: @escaping () -> Void) {
        queue.async { [self] in
            stopping = true
            servers.forEach { $0.close() }
            servers = []
            let group = DispatchGroup()
            for rt in bots.values {
                group.enter()
                stop(rt) { [self] in
                    rt.tracker.stopped()
                    push(.botChanged(rt.summary))
                    group.leave()
                }
            }
            group.notify(queue: queue) { [self] in
                if lockFD >= 0 { close(lockFD); lockFD = -1 }
                then()
            }
        }
    }

    // MARK: - Bots

    func addRuntime(_ bot: Bot) -> BotRuntime {
        let rt = BotRuntime(bot: bot, host: BotHost(botId: bot.id, queue: queue, delegate: self))
        let records = (try? store.records(bot: bot.id, afterSeq: 0)) ?? []
        records.forEach(rt.note)
        rt.unread = isUnread(lastReadSeq: store.meta(bot.id).lastReadSeq, records: records)
        if bot.archivedAt != nil { rt.tracker.stopped() }
        bots[bot.id] = rt
        return rt
    }

    /// Writes the bot's system prompt and hook settings, then starts its Claude Code (spec §3.2). Claude Code is checked
    /// first (spec §4): once per engine run, and again after a check that found it missing or signed out, since the user may
    /// have fixed it since; `checked` marks the launch that follows such a fresh check.
    func launch(_ rt: BotRuntime, checked: Bool = false) {
        rt.restart = nil
        guard !stopping, rt.bot.archivedAt == nil, !rt.host.isRunning,
              let project = store.projects.first(where: { $0.id == rt.bot.projectId }) else { return }
        guard rt.bot.agent == .claude else { return crashed(rt, "Codex bots are not supported yet") }
        guard let status = claudeStatus, checked || status.problem == nil else {
            return checkClaude { [weak self] _ in self?.launch(rt, checked: true) }
        }
        guard status.problem == nil, let claudePath = status.path else {
            return crashed(rt, (status.problem ?? .notInstalled).rawValue)
        }

        var isDirectory: ObjCBool = false
        let linkedExists = project.linkedFolder.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue } ?? false
        if let linked = project.linkedFolder, !linkedExists, rt.lastEvent?.event != .system(.linkedFolderMissing(path: linked)) {
            record(.system(.linkedFolderMissing(path: linked)), rt)
        }
        do {
            try store.prepareFolders(for: rt.bot)
            let instructions = linkedExists && project.readLinkedInstructions ? linkedInstructions(in: project.linkedFolder!) : nil
            let files = paths.bot(rt.bot.id)
            try systemPrompt(bot: rt.bot, project: project, paths: paths, linkedInstructions: instructions)
                .write(to: files.systemPrompt, atomically: true, encoding: .utf8)
            try claudeHookSettings(hookCommand: hookCommand).write(to: files.settings, options: .atomic)
        } catch {
            return crashed(rt, "Cannot prepare the bot's folder: \(error.localizedDescription)")
        }
        // Skills arrive as links in the bot's folder and in the project's shared one, which every bot gets with --add-dir
        // (spec §6.2); one that cannot be linked is left out and logged, the bot starts anyway (spec §9).
        for problem in linkSkills(rt.bot.skills, into: paths.bot(rt.bot.id).workspace)
            + linkSkills(project.skills, into: paths.shared(project.id)) {
            log("bot \(rt.bot.id): \(problem)")
        }
        rt.token = UUID().uuidString
        rt.normalizer = ClaudeNormalizer()
        rt.resumed = store.meta(rt.bot.id).hasStarted
        // The project's plugins and the bot's, each folder once; one no longer on this Mac is left out (spec §6.2-6.3).
        let plugins = ClaudeCatalog.pluginFolders(project.plugins + rt.bot.plugins,
                                                  in: ClaudeCatalog.plugins(root: claudeConfigRoot(environment: environment)))
        plugins.missing.forEach { log("bot \(rt.bot.id): plugin \($0) not found, left out") }
        let plan = claudeLaunchPlan(bot: rt.bot, project: project, paths: paths, claudePath: claudePath, resume: rt.resumed,
                                    baseEnvironment: environment, token: rt.token, linkedFolderExists: linkedExists,
                                    pluginFolders: plugins.folders)
        rt.tracker.processStarted()
        push(.botChanged(rt.summary))
        rt.host.start(plan)
    }

    /// Checks Claude Code off the queue (`claude auth status` alone may take 10 s, spec §9) and keeps the result in
    /// `claudeStatus`; `then` runs on the queue with it. Calls made while a check runs share it. While Claude Code has not
    /// been found it is looked for again, so installing it needs no engine restart.
    func checkClaude(then: @escaping (ClaudeStatus) -> Void) {
        claudeWaiters.append(then)
        guard claudeWaiters.count == 1 else { return }
        let (known, locate, env) = (claudeStatus?.path, locateClaude, botEnvironment(environment))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = ClaudeCheck.status(path: known ?? locate(), environment: env)
            self?.queue.async { [weak self] in
                guard let self else { return }
                claudeStatus = status
                let waiters = claudeWaiters
                claudeWaiters = []
                waiters.forEach { $0(status) }
            }
        }
    }

    /// `CLAUDE.md` and `AGENTS.md` of the linked folder, when present.
    private func linkedInstructions(in folder: String) -> String? {
        let texts = ["CLAUDE.md", "AGENTS.md"].compactMap {
            try? String(contentsOfFile: (folder as NSString).appendingPathComponent($0), encoding: .utf8)
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    private func crashed(_ rt: BotRuntime, _ reason: String) {
        rt.tracker.processExited(reason: reason, retryAt: nil)
        push(.botChanged(rt.summary))
    }

    /// Stops the bot's process; `then` runs once it has exited (at once if it was not running).
    func stop(_ rt: BotRuntime, then: @escaping () -> Void) {
        rt.restart?.cancel()
        rt.restart = nil
        rt.stopping = true
        rt.host.stop {
            rt.stopping = false
            then()
        }
    }

    func restart(_ rt: BotRuntime) {
        guard rt.bot.archivedAt == nil else { return }
        stop(rt) { [weak self] in self?.launch(rt) }
    }

    func archive(_ rt: BotRuntime) throws {
        rt.bot.archivedAt = Date()
        try store.save(bot: rt.bot)
        stop(rt) { [weak self] in
            rt.tracker.stopped()
            self?.push(.botChanged(rt.summary))
        }
    }

    /// Exit bookkeeping (spec §3.2): a resumed launch that died within 10 s starts a new conversation next time;
    /// the bot restarts after the backoff delay.
    private func exited(_ rt: BotRuntime, ranFor: TimeInterval, code: Int32?) {
        rt.token = UUID().uuidString                                 // late hooks from the dead process are dropped
        handle(rt.normalizer.flush(now: .distantFuture), rt)       // what the dead process had already said
        closeRequests(of: rt, .cancelled)
        // A turn cut short (crash, restart, shutdown) would stay "in progress" forever: close it as interrupted.
        if rt.tracker.state.inTurn { handle(rt.normalizer.interrupted(at: Date()), rt) }
        guard !rt.stopping, !stopping else { return }
        claudeStatus = nil          // a bot that falls checks Claude Code again before the next launch (spec §4)
        let reason = code.map { "Exit code \($0)" } ?? "Could not start"
        record(.system(.crashed(reason: reason)), rt)
        let newConversation = rt.resumed && ranFor < 10 && code != nil      // nil: the fork failed, claude never ran
        if newConversation {
            rt.bot.sessionId = UUID()
            try? store.save(bot: rt.bot)
            record(.system(.newConversation), rt)
        }
        updateMeta(rt) {
            $0.crashCount += 1
            if newConversation { $0.hasStarted = false }
        }
        let delay = rt.backoff.nextDelay(ranFor: ranFor)
        rt.tracker.processExited(reason: reason, retryAt: Date().addingTimeInterval(delay))
        push(.botChanged(rt.summary))
        let item = DispatchWorkItem { [weak self] in self?.launch(rt) }
        rt.restart = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Read-modify-write of the bot's meta. Never hold a meta copy across `record`: appending moves `lastSeq`.
    func updateMeta(_ rt: BotRuntime, _ change: (inout BotMeta) -> Void) {
        var meta = store.meta(rt.bot.id)
        change(&meta)
        do { try store.setMeta(meta, for: rt.bot.id) } catch { log("meta write failed for \(rt.bot.id): \(error)") }
    }

    // MARK: - Events and pushes

    /// Appends an event to the bot's history, updates its state and tells every app.
    func record(_ event: ChatEvent, _ rt: BotRuntime) {
        let record: ChatEventRecord
        do { record = try store.append(event, bot: rt.bot.id, at: Date()) } catch {
            return log("append failed for \(rt.bot.id): \(error)")
        }
        let (state, unread) = (rt.tracker.state, rt.unread)
        rt.tracker.apply(event)
        rt.note(record)
        if case .userMessage = event { rt.turn = [] }
        rt.turn.append(event)
        push(.chatEvent(botId: rt.bot.id, record: record))
        if rt.tracker.state != state || rt.unread != unread { push(.botChanged(rt.summary)) }
        // A user message means Claude Code saved a conversation: from now on launches use --resume.
        if case .userMessage = event, !store.meta(rt.bot.id).hasStarted { updateMeta(rt) { $0.hasStarted = true } }
        if case .turnEnded = event {
            closeRequests(of: rt, .answeredInTerminal)      // safety net: nothing can still be waiting after the turn
            repairTranscript(rt)
        }
    }

    func push(_ push: Push) { send(.push(push), to: apps.values.map(\.connection)) }

    /// Output an app may leave unread before it is dropped; it reconnects and takes a fresh snapshot.
    static let maxPendingOutput = 64 << 20

    func send(_ message: EngineMessage, to connections: [LineConnection]) {
        guard !connections.isEmpty else { return }
        guard let line = try? encoder.encode(message) else { return log("cannot encode \(message)") }
        for connection in connections {
            connection.send(line)
            if connection.pendingBytes > Self.maxPendingOutput {
                log("app connection dropped: more than 64 MiB unread")
                connection.close()
            }
        }
    }

    /// Appends one line to `serifd.log`.
    func log(_ message: String) { Self.log(message, to: paths) }

    /// Appends one timestamped line to the data folder's `serifd.log` (also used by serifd before an engine exists).
    public static func log(_ message: String, to paths: SerifPaths) {
        let fd = open(paths.log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let line = Array("\(Date()) \(message)\n".utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}

extension Engine: BotHostDelegate {
    public func botHost(_ host: BotHost, output data: Data, seq: Int) {
        let viewers = apps.values.filter { $0.terminals.contains(host.botId) }.map(\.connection)
        send(.push(.terminalOutput(botId: host.botId, seq: seq, data: data)), to: viewers)
    }

    public func botHost(_ host: BotHost, screen signals: Set<ScreenSignal>) {
        guard let rt = bots[host.botId] else { return }
        if !signals.isDisjoint(with: [.trustPrompt, .trustConfirm]) { answerTrust(rt) }
        // Only during a turn: a resumed conversation shows its last "Interrupted" again on screen (seen live).
        if signals.contains(.interrupted), rt.tracker.state.inTurn { interrupted(rt) }
        // .planApproval is read from the live screen when the user approves a plan (see `answer`).
    }

    /// The trust dialog starts on "No, exit": Down moves to "Yes, I trust this folder", Enter confirms it. Keys go one at a
    /// time by what is selected now, and the screen is read again every second while the dialog is up: Claude Code can
    /// re-mount it right after its first paint and drop keys sent too early (seen live with 2.1.296).
    func answerTrust(_ rt: BotRuntime) {
        rt.trustCheck?.cancel()
        rt.trustCheck = nil
        guard rt.host.isRunning else { return }
        let signals = screenSignals(in: rt.host.screenText)
        if signals.contains(.trustPrompt) { rt.host.write([0x1B, 0x5B, 0x42]) }
        else if signals.contains(.trustConfirm) { rt.host.write([0x0D]) }
        else { return }
        let item = DispatchWorkItem { [weak self] in self?.answerTrust(rt) }
        rt.trustCheck = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    public func botHostStarted(_ host: BotHost) {}

    public func botHost(_ host: BotHost, exited code: Int32?, ranFor: TimeInterval) {
        guard let rt = bots[host.botId] else { return }
        exited(rt, ranFor: ranFor, code: code)
    }
}
