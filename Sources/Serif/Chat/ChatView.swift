import SwiftUI
import SerifCore

/// The centre pane: header, conversation, composer. Reads only the selected bot's slice of the client state.
struct ChatView: View {
    let client: EngineClient
    @Binding var showPanel: Bool
    @Binding var showTerminal: Bool
    @AppStorage(OnboardingView.doneKey) private var onboardingDone = false

    var body: some View {
        Group {
            if client.showWaiting {
                WaitingView(client: client)
            } else if let summary = client.chat.summary {
                ChatContent(client: client, summary: summary, transcript: client.chat.transcript,
                            pending: client.chat.pending, showPanel: $showPanel, showTerminal: $showTerminal)
                    .id(summary.bot.id)    // fresh scroll and composer state per bot
            } else if client.roster.connected && client.roster.projects.isEmpty {
                if onboardingDone { NoProjectsView(client: client) } else { OnboardingView(client: client) }
            } else {
                Text(client.roster.connected ? String(localized: "Choose a bot") : String(localized: "Connecting to the engine…"))
                    .font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.pane)
    }
}

private struct ChatContent: View {
    let client: EngineClient
    let summary: BotSummary
    let transcript: Transcript?
    let pending: [String]
    @Binding var showPanel: Bool
    @Binding var showTerminal: Bool
    @Environment(\.controlActiveState) private var activeState
    @State private var atBottom = true
    @State private var userScrolling = false
    @State private var expandedSteps: Set<String> = []
    @State private var openStep: [String: String] = [:]
    @State private var columnWidth: CGFloat = 700
    @State private var loadingEarlier = false
    @State private var earlierAnchor: String?    // the item kept in place while an older page is added above it

    private var items: [ChatItem] { transcript?.items ?? [] }
    private var working: Activity? { if case .working(let a) = summary.state { a } else { nil } }
    private var isWorking: Bool { working != nil }
    /// Stopped because its agent is missing or signed out: the chat shows how to fix it (spec §4 of 0.3, §7).
    private var needsAgentHelp: Bool {
        if case .crashed(let reason, _) = summary.state { return AgentProblem(rawValue: reason) != nil }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showTerminal {
                BigTerminal(session: client.terminal(for: summary.bot.id), running: summary.state.hasProcess).padding(.leading, 8)
                    .overlay { StoppedOverlay(state: summary.state) }
                    .overlay {
                        // Codex opens a conversation in its terminal only after its first turn (spec §4).
                        if summary.bot.agent == .codex, summary.bot.threadId == nil, summary.state.hasProcess {
                            Text(String(localized: "The terminal opens after the first message"))
                                .font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.pane)
                        }
                    }
            } else {
            ZStack(alignment: .bottom) {
                conversation
                LinearGradient(colors: [Theme.pane.opacity(0), Theme.pane], startPoint: .top, endPoint: .bottom)
                    .frame(height: 40).allowsHitTesting(false)
                if !atBottom { jumpButton.padding(.bottom, 8) }
            }
            Composer(botName: summary.bot.name, working: isWorking, onSend: { text, files in
                atBottom = true; bottomRequest += 1    // your own message always brings the chat to the bottom
                do { try await client.sendMessage(bot: summary.bot.id, text: text, files: files); return true } catch { return false }
            }, onStop: { Task { try? await client.interrupt(bot: summary.bot.id) } })
            .padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 4)
            }
        }
        .task { if transcript == nil { await client.loadHistory(bot: summary.bot.id) } }
        // Debounced by task(id:): mark read once new items settled, while the chat is visible and the window is key.
        .task(id: ReadKey(seq: transcript?.lastSeq ?? 0, key: activeState == .key, unread: summary.unread)) {
            guard activeState == .key, summary.unread, let seq = transcript?.lastSeq, seq > 0 else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { try? await client.markRead(bot: summary.bot.id, seq: seq) }
        }
    }

    private struct ReadKey: Hashable { let seq: Int; let key: Bool; let unread: Bool }

    private var header: some View {
        HStack(spacing: 10) {
            BotAvatar(summary: summary, size: 24, alive: true)
            Text(summary.bot.name).font(.system(size: 16, weight: .medium))
            TimelineView(summary.state.retrySchedule) { _ in
                if let t = stateText(summary.state) {
                    Text(t).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            Picker("", selection: $showTerminal) {
                Text("Chat").tag(false)
                Text("Terminal").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            Button { showPanel.toggle() } label: {
                Image(systemName: "display").font(.system(size: 15)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(showPanel ? Theme.text : Theme.textSecondary)
            .help(String(localized: "Show the bot's screen"))
        }
        .padding(.horizontal, 20).frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderTertiary).frame(height: 1) }
    }

    private var jumpButton: some View {
        Button { atBottom = true; bottomRequest += 1 } label: {
            Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32).background(Circle().fill(Theme.composerFill))
                .overlay(Circle().stroke(Theme.composerBorder, lineWidth: 1))
        }
        .buttonStyle(.plain).help(String(localized: "Jump to the latest"))
    }

    @State private var bottomRequest = 0

    /// Vertical gap above `item` given the one before it: tight inside a run by one speaker, loose across speakers.
    private func gap(_ prev: ChatItem?, _ item: ChatItem) -> CGFloat {
        guard let prev else { return 16 }
        func side(_ i: ChatItem) -> Int {
            switch i { case .user: 1; case .assistant, .steps, .request: 0; default: 2 }
        }
        if case .timestamp = item { return 24 }
        if case .timestamp = prev { return 12 }
        if case .system = item { return 16 }
        if case .system = prev { return 16 }
        if case .routineRun = item { return 16 }
        if case .routineRun = prev { return 16 }
        if case .steps = item { return 8 }
        if case .steps = prev { return 8 }
        return side(prev) == side(item) ? 4 : 12
    }

    private var conversation: some View {
        let maxBubble = columnWidth * 0.78
        return ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: with a very tall row (a 300-line reply) a lazy stack over-estimated the history and opened the
                // chat past its end, blank (seen live). A page is 200 events and older pages load only on request, so the rows
                // stay cheap.
                VStack(spacing: 0) {
                    if let first = transcript?.firstSeq, first > 1 { earlierButton }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        row(item, maxBubble).padding(.top, gap(i > 0 ? items[i - 1] : nil, item))
                    }
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, text in
                        UserBubble(text: text, origin: .chat, pending: true, maxWidth: maxBubble)
                            .padding(.top, gap(items.last, .user(id: "", text: "", origin: .chat, at: .now)))
                    }
                    if needsAgentHelp {
                        AgentHelpCard(client: client, agent: summary.bot.agent).padding(.top, 14)
                    }
                    if let a = working {
                        LiveStatus(summary: summary, activity: a).padding(.top, 14)
                    }
                    Color.clear.frame(height: 48).id("bottom")    // room for the fade
                }
                .padding(.horizontal, 20).padding(.bottom, 4)
            }
            .defaultScrollAnchor(.bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 40 } action: { columnWidth = $0 }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 60
            } action: { _, now in
                // Reaching the bottom always counts; leaving it only when the user scrolled, not when content grew.
                if now { atBottom = true } else if userScrolling { atBottom = false }
            }
            .onScrollPhaseChange { _, phase in userScrolling = phase == .interacting || phase == .decelerating }
            .onChange(of: scrollTick) {
                if let anchor = earlierAnchor { earlierAnchor = nil; proxy.scrollTo(anchor, anchor: .top) }
                else if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: bottomRequest) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    /// History paging (spec §3.6): the 200 events before the oldest loaded one. The first message on screen stays in place
    /// (a timestamp line can disappear once older messages join its group, so it is never the anchor).
    private var earlierButton: some View {
        Button(String(localized: "Load earlier messages")) {
            earlierAnchor = items.first { if case .timestamp = $0 { false } else { true } }?.id
            atBottom = false
            loadingEarlier = true
            Task { await client.loadEarlier(bot: summary.bot.id); loadingEarlier = false }
        }
        .buttonStyle(.plain).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
        .disabled(loadingEarlier).padding(.top, 12)
    }

    /// Changes whenever something is added or a streaming reply grows.
    private var scrollTick: Int {
        var h = Hasher()
        h.combine(items.count); h.combine(pending.count); h.combine(isWorking); h.combine(needsAgentHelp)
        if case .assistant(_, let t, _, _)? = items.last { h.combine(t.utf8.count) }
        if case .steps(_, let s, _)? = items.last { h.combine(s.count) }
        return h.finalize()
    }

    @ViewBuilder private func row(_ item: ChatItem, _ maxBubble: CGFloat) -> some View {
        switch item {
        case .timestamp(_, let at): TimestampLine(at: at)
        case .user(_, let text, let origin, _, let attachments):
            UserBubble(text: text, origin: origin, maxWidth: maxBubble, attachments: attachments, projectId: summary.bot.projectId)
        case .assistant(_, let text, _, _): AssistantBubble(text: text, maxWidth: maxBubble)
        case .steps(let id, let steps, let status):
            StepsCard(steps: steps, status: status,
                      expanded: Binding(get: { expandedSteps.contains(id) },
                                        set: { if $0 { expandedSteps.insert(id) } else { expandedSteps.remove(id) } }),
                      open: Binding(get: { openStep[id] }, set: { openStep[id] = $0 }))
        case .request(_, let req, let resolution, let answer):
            RequestCard(request: req, resolution: resolution, given: answer, client: client)
        case .system(_, let note, _): SystemLine(note: note, botName: summary.bot.name)
        case .mail(_, let note, _): MailRow(note: note, maxWidth: maxBubble)
        case .task(_, let card): TaskCardView(card: card, projectId: summary.bot.projectId, client: client)
        case .routineRun(_, let run): RoutineRunLine(run: run)
        }
    }
}
