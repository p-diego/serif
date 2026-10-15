import Foundation
import SerifCore

// hook.sock: one connection per hook call from serif-hook. Non-blocking events are answered at once; a
// PermissionRequest keeps its connection until it is answered, resolved in the terminal or cancelled (spec §3.5).
extension Engine {
    func hookConnected(_ connection: LineConnection) {
        connection.onLine = { [weak self] line in self?.hookLine(line, from: connection) }
        connection.onClose = { [weak self] in self?.hookClosed(connection) }
    }

    private func hookLine(_ line: Data, from connection: LineConnection) {
        guard let envelope = try? decoder.decode(HookEnvelope.self, from: line) else {
            log("unreadable hook line dropped")
            return reply(connection, nil)
        }
        // Unknown or archived bot, or a token from another launch: dropped.
        guard let id = UUID(uuidString: envelope.botId), let rt = bots[id], rt.bot.archivedAt == nil,
              rt.token == envelope.token else { return reply(connection, nil) }
        // A call of the bot's Serif tools (spec §4), not a hook: its result goes back as JSON.
        if let tool = envelope.payload["tool"]?.string {
            let result = handleTool(tool, envelope.payload["arguments"] ?? [:], from: rt)
            return reply(connection, (try? JSONEncoder().encode(result)).map { String(decoding: $0, as: UTF8.self) })
        }
        let event = envelope.payload["hook_event_name"]?.string
        let waits = event == "PermissionRequest"
        if !waits { reply(connection, nil) }
        // The conversation changed under us (e.g. /clear): the next --resume must open the new one.
        if event == "SessionStart", let session = envelope.payload["session_id"]?.string.flatMap(UUID.init(uuidString:)),
           session != rt.bot.sessionId {
            rt.bot.sessionId = session
            do { try store.save(bot: rt.bot) } catch { log("cannot save the new session id of \(id): \(error)") }
            push(.botChanged(rt.summary))
        }
        handle(rt.normalizer.ingest(envelope.payload, at: Date()), rt, hook: waits ? connection : nil)
        // Never leave a hook waiting on a request that was not opened.
        if waits, !requests.values.contains(where: { $0.asker.isHook(connection) }) { reply(connection, nil) }
    }

    /// serif-hook went away (killed by Esc, or Claude Code gave up): its request is cancelled.
    private func hookClosed(_ connection: LineConnection) {
        for (id, open) in requests where open.asker.isHook(connection) { closeRequest(id, .cancelled, replied: true) }
    }

    func reply(_ connection: LineConnection, _ stdout: String?) {
        guard let line = try? encoder.encode(HookReply(stdout: stdout)) else { return }
        connection.send(line)
    }

    /// Applies the normalizer's outputs to the store, the bot's state and the apps.
    func handle(_ outputs: [NormalizerOutput], _ rt: BotRuntime, hook: LineConnection? = nil) {
        for output in outputs {
            switch output {
            case let .event(event):
                record(event, rt)
            case let .permissionRequest(toolName, input, suggestions, promptId, toolUseId):
                guard let hook else { continue }
                let request = PendingRequest(botId: rt.bot.id, kind: PendingRequest.kind(forTool: toolName), toolName: toolName,
                                             input: input, toolUseId: toolUseId, promptId: promptId, suggestions: suggestions)
                requests[request.id] = (request, .hook(hook))
                record(.requestOpened(request), rt)
                push(.requestOpened(request))
            case let .toolResolved(toolUseId):
                closeRequests(of: rt, .answeredInTerminal) { $0.toolUseId == toolUseId }
            case .sessionStarted:
                let state = rt.tracker.state
                rt.tracker.sessionStarted()
                if rt.tracker.state != state { push(.botChanged(rt.summary)) }
                deliverOutbox(rt)
                deliverMail(rt)                             // mail that waited while it was down (spec §6)
            case .rateLimited:
                rt.tracker.rateLimited(until: nil)
                push(.botChanged(rt.summary))
            case let .transcriptPath(path):
                rt.transcriptPath = path
            case let .serverRequest(id, toolName, input, decisions, turnId, itemId):
                let request = PendingRequest(botId: rt.bot.id, kind: PendingRequest.kind(forTool: toolName), toolName: toolName,
                                             input: input, toolUseId: itemId, promptId: turnId, suggestions: nil, decisions: decisions)
                requests[request.id] = (request, .codex(id))
                record(.requestOpened(request), rt)
                push(.requestOpened(request))
            case let .serverRequestResolved(id):
                // Answered in the terminal: Serif's own answers have closed their card already.
                for (key, open) in requests where open.request.botId == rt.bot.id {
                    if case let .codex(asked) = open.asker, asked == id { closeRequest(key, .answeredInTerminal) }
                }
            case .sessionEnded, .notification:
                break
            }
        }
        scheduleFlush(rt)
    }

    /// Types a message into the bot's terminal; the normalizer then gives its UserPromptSubmit this origin.
    func type(_ text: String, origin: MessageOrigin = .chat, attachments: [String]? = nil, into rt: BotRuntime) {
        let sent = outgoingText(Outgoing(text: text, origin: origin, attachments: attachments), rt)
        rt.normalizer.expectChatMessage(sent, origin: origin, shown: sent == text ? nil : text, attachments: attachments)
        rt.awaitingEcho = true
        rt.host.typeMessage(sent)
    }

    /// The text as the agent gets it (spec §4, §6 of 0.7): the message with its files, headed by the new instructions
    /// when they changed since the bot's start; that notice goes once, with whatever message comes first.
    func outgoingText(_ m: Outgoing, _ rt: BotRuntime) -> String {
        var sent = messageText(m.text, attachments: m.attachments ?? [])
        if rt.instructionsPending {
            sent = instructionsNotice(rt.bot.instructions, before: sent)
            rt.instructionsPending = false
        }
        return sent
    }

    /// Types the texts held back (before SessionStart, or while a request was open), in order.
    func deliverOutbox(_ rt: BotRuntime) {
        let queued = rt.outbox
        rt.outbox = []
        queued.forEach { type($0.text, origin: $0.origin, attachments: $0.attachments, into: rt) }
    }

    /// A card that holds the bot; a decision's never does (spec §6 of 0.6).
    func hasOpenRequest(_ rt: BotRuntime) -> Bool {
        requests.values.contains { $0.request.botId == rt.bot.id && $0.request.kind != .decision }
    }

    /// Esc was pressed (seen on screen): open requests are cancelled, then the turn closes as interrupted.
    func interrupted(_ rt: BotRuntime) {
        closeRequests(of: rt, .cancelled)
        handle(rt.normalizer.interrupted(at: Date()), rt)
    }

    /// Closes the bot's open cards at the end of a turn, on Esc, when its process goes. Never a decision's: that one
    /// closes only with your answer, its withdrawal or the bot's archiving (spec §6 of 0.6).
    func closeRequests(of rt: BotRuntime, _ how: RequestResolution, where match: (PendingRequest) -> Bool = { _ in true }) {
        for (id, open) in requests
        where open.request.botId == rt.bot.id && open.request.kind != .decision && match(open.request) {
            closeRequest(id, how)
        }
    }

    /// Forgets an open request, releases its serif-hook (printing nothing, unless already `replied`) and tells everyone.
    func closeRequest(_ id: UUID, _ how: RequestResolution, replied: Bool = false, answer: RequestAnswer? = nil) {
        guard let open = requests.removeValue(forKey: id), let rt = bots[open.request.botId] else { return }
        if !replied, case let .hook(hook) = open.asker { reply(hook, nil) }
        record(.requestClosed(requestId: id, resolution: how, answer: answer), rt)
        push(.requestClosed(requestId: id, botId: rt.bot.id, resolution: how, answer: answer))
        guard !hasOpenRequest(rt) else { return }
        guard rt.bot.agent == .claude else { return deliverMail(rt) }      // Codex texts never wait on cards
        // Texts held during the request, then mail. Claude Code drops its dialog only after it has read the hook's
        // answer: typed at once, the Enter could still land in it. Sent 1 s later, unless a new request opened or the
        // bot went down (then the next SessionStart delivers them).
        // ponytail: fixed 1 s delay; read the screen for the dialog if a slow Mac ever lets it through.
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak rt] in
            guard let self, let rt, rt.host.isRunning, !rt.stopping, !hasOpenRequest(rt) else { return }
            switch rt.tracker.state {
            case .starting, .crashed, .stopped: return
            default: deliverOutbox(rt); deliverMail(rt)
            }
        }
    }

    /// One timer per bot, set to the normalizer's next hold deadline.
    private func scheduleFlush(_ rt: BotRuntime) {
        guard let deadline = rt.normalizer.nextDeadline else { return }
        if rt.flushTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self, weak rt] in
                guard let self, let rt else { return }
                self.handle(rt.normalizer.flush(now: Date()), rt)
            }
            timer.resume()
            rt.flushTimer = timer
        }
        rt.flushTimer?.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow))
    }

    /// After a turn ends, restores the lines MessageDisplay skipped from Claude Code's own transcript (spec §3.4).
    /// The file can be tens of MB: it is read and parsed off the engine queue, and only the fixes come back to it.
    /// Any failure (no file, prompt not found, counts that do not match) leaves the chat as it is.
    func repairTranscript(_ rt: BotRuntime) {
        let turn = rt.turn
        rt.turn = []
        guard let path = rt.transcriptPath, case let .userMessage(prompt, _, _, _)? = turn.first else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let jsonl = try? String(contentsOfFile: path, encoding: .utf8),
                  let texts = transcriptTexts(transcriptJSONL: jsonl, prompt: prompt) else { return }
            let fixes = repairs(turn: turn, transcript: texts)
            var order: [String] = []
            var replaced: [String: String] = [:]          // Stop's own repair may already have set the same text
            for event in turn {
                if case let .assistantText(id, _, _, _, _) = event, !order.contains(id) { order.append(id) }
                if case let .assistantTextReplaced(id, text) = event { replaced[id] = text }
            }
            let updates = order.compactMap { id in fixes[id].flatMap { $0 == replaced[id] ? nil : (id, $0) } }
            guard !updates.isEmpty else { return }
            self?.queue.async { [weak self] in
                guard let self, rt.bot.archivedAt == nil else { return }
                for (id, text) in updates { record(.assistantTextReplaced(messageId: id, text: text), rt) }
            }
        }
    }
}

extension Engine.Asker {
    func isHook(_ connection: LineConnection) -> Bool { if case let .hook(hook) = self { hook === connection } else { false } }
}
