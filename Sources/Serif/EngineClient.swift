import Foundation
import Observation
import ServiceManagement
import SerifCore

struct EngineError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to serifd: keeps the socket up (retrying every second), sends requests and folds pushes into `state`.
@MainActor @Observable
final class EngineClient {
    private(set) var state = ClientState() {
        didSet {
            // Only republish what the sidebar shows, so transcript deltas don't make it re-evaluate.
            if roster.projects != state.projects || roster.bots != state.bots { roster.projects = state.projects; roster.bots = state.bots
                // Terminals follow the roster: drop archived bots' sessions, let waiting views retry.
                sessions = sessions.filter { state.bots[$0.key] != nil }
                for session in sessions.values { session.nudge() }
                onWaitingCount?(state.waitingCount)
            }
            if roster.requests != state.requests { roster.requests = state.requests }
            if roster.connected != state.connected { roster.connected = state.connected }
            refreshChat()
        }
    }
    /// What the open chat shows; republished only when it changes, so other bots' deltas don't re-render it.
    struct ChatSlice: Equatable {
        var summary: BotSummary?
        var transcript: Transcript?    // nil until the history is first asked for
        var pending: [String] = []
    }
    /// Hooks for the out-of-window signals (Dock badge, notifications).
    @ObservationIgnored var onWaitingCount: ((Int) -> Void)?
    @ObservationIgnored var onChatEvent: ((UUID, ChatEventRecord) -> Void)?
    private(set) var chat = ChatSlice()
    private func refreshChat() {
        var slice = ChatSlice()
        if let id = selectedBot {
            slice = ChatSlice(summary: state.bots[id], transcript: state.transcripts[id], pending: state.pendingSends[id] ?? [])
        }
        if slice != chat { chat = slice }
    }
    /// Projects and bot summaries only (no transcripts or requests): the sidebar observes this, not `state`.
    private(set) var roster = ClientState()
    var selectedBot: UUID? { didSet { refreshChat() } }
    /// The sheet shown over the main window, if any.
    enum Sheet: Identifiable, Equatable {
        case newProject
        case newBot(projectId: UUID?)
        case editBot(UUID)
        case editProject(UUID)
        var id: String {
            switch self {
            case .newProject: "project"
            case .newBot: "new-bot"
            case .editBot(let id): "bot-\(id)"
            case .editProject(let id): "project-\(id)"
            }
        }
    }
    var sheet: Sheet?
    func showNewBot() { sheet = .newBot(projectId: nil) }
    func showNewProject() { sheet = .newProject }
    func showBotSettings(_ id: UUID) { sheet = .editBot(id) }
    func showProjectSettings(_ id: UUID) { sheet = .editProject(id) }

    @ObservationIgnored private let queue = DispatchQueue(label: "serif.engine-client")
    @ObservationIgnored private var connection: LineConnection?
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<ResponseBody, Error>] = [:]
    @ObservationIgnored private let encoder = protocolEncoder()
    @ObservationIgnored private let decoder = protocolDecoder()
    @ObservationIgnored private let socketPath = SerifPaths.standard().engineSocket.path
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sessions: [UUID: TerminalSession] = [:]

    /// The one shared terminal connection of a bot (preview and big view both use it).
    func terminal(for bot: UUID) -> TerminalSession {
        if let session = sessions[bot] { return session }
        let session = TerminalSession(botId: bot, client: self)
        sessions[bot] = session
        return session
    }

    func start() {
        guard !started else { return }
        started = true
        startEngine()
        connect()
    }

    /// True for a bundle under /Applications or ~/Applications.
    static var runsFromApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasSuffix(".app") && (path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
    }

    /// The installed engine agent waits for the user's approval in System Settings; meanwhile the app runs serifd itself.
    private(set) var engineNeedsApproval = false
    @ObservationIgnored private let engineAgent = SMAppService.agent(plistName: "com.serif.engine.plist")

    /// Installed: registers the launchd agent. Then, if nobody answers within 2 s (a dev build, or an agent macOS has not
    /// approved or started), runs serifd from our own bundle; a second engine on the same data folder exits at once
    /// (the folder is locked), so a late launchd start is harmless. Also the "Start" button of the engine-off overlay.
    func startEngine() {
        if Self.runsFromApplications {
            do { try engineAgent.register() } catch { NSLog("Serif: registering engine failed: \(error)") }
            refreshEngineApproval()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !self.state.connected else { return }
            Self.spawnEngine()
        }
    }

    /// Re-read when the app comes forward: the user may have just allowed the agent in System Settings.
    func refreshEngineApproval() {
        guard Self.runsFromApplications else { return }
        engineNeedsApproval = engineAgent.status == .requiresApproval
    }

    private static func spawnEngine() {
        // Installed with the agent loaded but not running (e.g. after "Quit and stop the bots"): launchd starts it, and
        // keeps restarting it on a crash. Otherwise serifd runs as our child.
        if runsFromApplications, run("/bin/launchctl", ["kickstart", "gui/\(getuid())/com.serif.engine"]) { return }
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        let process = Process()
        process.executableURL = dir.appendingPathComponent("serifd")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { NSLog("Serif: cannot start serifd: \(error)") }    // not waited for: it outlives us
    }

    /// Runs a short command to its end; true if it exited with 0. Blocking: also used off the main actor.
    nonisolated static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: connection

    private func connect() {
        let path = socketPath
        let queue = queue
        queue.async { [weak self] in
            let connection = LineClient.connect(path: path, queue: queue)
            if let connection {
                connection.onLine = { [weak self] line in
                    Task { @MainActor in self?.receive(line) }
                }
                connection.onClose = { [weak self, weak connection] in
                    Task { @MainActor in if let connection { self?.closed(connection) } }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                if let connection { self.opened(connection) } else { self.retry() }
            }
        }
    }

    private func opened(_ connection: LineConnection) {
        self.connection = connection
        Task {
            do {
                let hello = try await send(.hello(protocolVersion: SerifProtocol.version))
                if case .welcome = hello {} else { throw EngineError(message: "Unexpected reply to hello") }
                guard case .snapshot(let snapshot) = try await send(.snapshot) else {
                    throw EngineError(message: "Unexpected reply to snapshot")
                }
                let loaded = Array(state.transcripts.keys)
                state.apply(snapshot: snapshot)
                state.pendingSends = [:]    // whatever was in flight before the outage is gone or already in the history
                // Events missed during an outage: replace each loaded transcript with the fresh first page. All are emptied
                // first so pushes for a bot still waiting its turn are kept, not dropped.
                for session in sessions.values { session.reconnected() }
                for bot in loaded { state.transcripts[bot] = Transcript() }
                for bot in loaded { await loadHistory(bot: bot) }
            } catch {
                NSLog("Serif: engine handshake failed: \(error)")
                // Drop the connection so the retry path runs.
                queue.async { connection.close() }
                closed(connection)
            }
        }
    }

    private func closed(_ connection: LineConnection) {
        guard self.connection === connection else { return }
        self.connection = nil
        state.disconnected()
        let pending = waiting
        waiting = [:]
        for continuation in pending.values { continuation.resume(throwing: EngineError(message: "Engine disconnected")) }
        retry()
    }

    private func retry() {
        state.disconnected()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.connect()
        }
    }

    private func receive(_ line: Data) {
        guard let message = try? decoder.decode(EngineMessage.self, from: line) else {
            // A response we cannot read must not leave its caller waiting forever.
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let response = object["response"] as? [String: Any], let id = response["id"] as? Int {
                waiting.removeValue(forKey: id)?.resume(throwing: EngineError(message: "Unreadable reply from the engine"))
            }
            return
        }
        switch message {
        case .response(let id, let body):
            waiting.removeValue(forKey: id)?.resume(returning: body)
        case .push(let push):
            if case .terminalOutput(let bot, let seq, let data) = push { sessions[bot]?.output(seq: seq, data: data) }
            state.apply(push)
            if case .chatEvent(let bot, let record) = push { onChatEvent?(bot, record) }
        }
    }

    // MARK: requests

    func send(_ request: AppRequest) async throws -> ResponseBody {
        guard let connection else { throw EngineError(message: "Engine not connected") }
        let id = nextId
        nextId += 1
        let line = try encoder.encode(RequestEnvelope(id: id, request: request))
        let body = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResponseBody, Error>) in
            waiting[id] = continuation
            queue.async { connection.send(line) }
        }
        if case .error(let message) = body { throw EngineError(message: message) }
        return body
    }

    /// The latest page of a bot's chat. Pushes arriving meanwhile are kept and merged; a failed load is tried once more.
    func loadHistory(bot: UUID) async {
        state.historyRequested(bot: bot)
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if case .history(let records)? = try? await send(.history(botId: bot, beforeSeq: nil, limit: 200)) {
                return state.historyLoaded(records, bot: bot)
            }
        }
    }

    /// The page before the oldest loaded record ("Load earlier messages").
    func loadEarlier(bot: UUID) async {
        guard let first = state.transcripts[bot]?.firstSeq, first > 1,
              case .history(let records)? = try? await send(.history(botId: bot, beforeSeq: first, limit: 200)) else { return }
        state.historyLoaded(records, bot: bot)
    }

    // MARK: actions used by views

    @discardableResult
    func createProject(name: String, linkedFolder: String? = nil, readLinkedInstructions: Bool = true) async throws -> Project {
        guard case .project(let project) = try await send(.createProject(name: name, linkedFolder: linkedFolder, readLinkedInstructions: readLinkedInstructions))
        else { throw EngineError(message: "Unexpected reply") }
        return project
    }
    /// Creates the bot and selects it. The first bot ends the first launch (spec §4).
    func createBot(_ bot: NewBot) async throws {
        guard case .bot(let created) = try await send(.createBot(bot)) else { throw EngineError(message: "Unexpected reply") }
        UserDefaults.standard.set(true, forKey: OnboardingView.doneKey)
        selectedBot = created.id
    }
    func updateBot(_ bot: Bot) async throws { _ = try await send(.updateBot(bot)) }
    func updateProject(_ project: Project) async throws { _ = try await send(.updateProject(project)) }
    func restart(bot: UUID) async throws { _ = try await send(.restartBot(id: bot)) }
    func archive(bot: UUID) async throws { _ = try await send(.archiveBot(id: bot)) }

    func sendMessage(bot: UUID, text: String) async throws {
        state.pendingSends[bot, default: []].append(text)
        do { _ = try await send(.send(botId: bot, text: text)) } catch {
            if let i = state.pendingSends[bot]?.firstIndex(of: text) { state.pendingSends[bot]?.remove(at: i) }
            throw error
        }
    }
    func interrupt(bot: UUID) async throws { _ = try await send(.interrupt(botId: bot)) }
    func answer(request: UUID, _ answer: RequestAnswer) async throws { _ = try await send(.answer(requestId: request, answer: answer)) }
    func markRead(bot: UUID, seq: Int) async throws { _ = try await send(.markRead(botId: bot, seq: seq)) }
    func attachTerminal(bot: UUID) async throws -> ResponseBody { try await send(.attachTerminal(botId: bot)) }
    func detachTerminal(bot: UUID) async throws { _ = try await send(.detachTerminal(botId: bot)) }
    func terminalInput(bot: UUID, data: Data) async throws { _ = try await send(.terminalInput(botId: bot, data: data)) }
    func resizeTerminal(bot: UUID, cols: Int, rows: Int) async throws { _ = try await send(.resizeTerminal(botId: bot, cols: cols, rows: rows)) }
    func shutdownEngine() async throws { _ = try await send(.shutdown) }
    /// An agent as the engine sees it (installed, version, signed in); the engine checks again on every call.
    func agentStatus(_ agent: Agent) async throws -> AgentStatus {
        guard case .agentStatus(let status) = try await send(.agentStatus(agent)) else { throw EngineError(message: "Unexpected reply") }
        return status
    }
}
