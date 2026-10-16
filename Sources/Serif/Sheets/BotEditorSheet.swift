import SwiftUI
import SerifCore

/// New bot (`editing == nil`) or settings of an existing one.
struct BotEditorSheet: View {
    let client: EngineClient
    let editing: Bot?
    @State private var projectId: UUID?
    @State private var template: BotTemplate?          // nil = Blank
    @State private var name: String
    @State private var face: BotFace
    @State private var agent: Agent
    @State private var baseAgent: Agent                   // the bot's agent as the form knows it: a restore moves it
    @State private var stashed: (model: BotModel, codexModel: String?, plugins: [String])?   // the values before a switch
    @State private var model: BotModel                    // a Claude Code bot's
    @State private var codexModel: String?                // a Codex bot's (nil: Codex's default)
    @State private var instructions: String
    @State private var freedom: Freedom
    @State private var notifications: Bool
    @State private var skills: [String]
    @State private var plugins: [String]
    @State private var connectors: Bool
    @State private var catalog = ClaudeCatalog()          // read when the sheet opens
    @State private var codexSkills: [CatalogItem] = []
    @State private var codexCatalog: CodexCatalog?        // asked of the engine when the sheet opens (spec §6)
    @State private var codexStatus: AgentStatus?          // Codex can be chosen once the engine finds it ready (spec §7)
    @State private var codexChecked = false               // the check answered or failed
    @State private var claudeStatus: AgentStatus?         // for a Codex bot's switch to Claude Code (spec §7 of 0.7)
    @State private var changes: [BotChange] = []          // the bot's history, newest last (spec §5 of 0.7)
    @State private var busy = false
    @State private var error: String?
    @State private var confirmArchive = false
    @State private var height = sheetHeight(1200)    // measured once: never re-derived while typing
    @State private var routineEditor: RoutineEditing?   // the routine sheet over this one (spec §4 of 0.6)
    @FocusState private var nameFocused: Bool

    /// What the routine sheet edits: nil is a new routine.
    private struct RoutineEditing: Identifiable {
        let id = UUID()
        let routine: Routine?
    }

    init(client: EngineClient, editing: Bot?, projectId: UUID?) {
        self.client = client
        self.editing = editing
        let roster = client.roster
        _projectId = State(initialValue: editing?.projectId ?? projectId
            ?? defaultProjectId(projects: roster.projects, selectedBotProject: client.selectedBot.flatMap { roster.bots[$0]?.bot.projectId }))
        _name = State(initialValue: editing?.name ?? "")
        _face = State(initialValue: editing?.face ?? randomFace(existing: roster.bots.values.map(\.bot.face)))
        _agent = State(initialValue: editing?.agent ?? .claude)
        _baseAgent = State(initialValue: editing?.agent ?? .claude)
        _model = State(initialValue: BotModel(value: editing?.agent == .codex ? nil : editing?.model))
        _codexModel = State(initialValue: editing?.agent == .codex ? editing?.model : nil)
        _instructions = State(initialValue: editing?.instructions ?? "")
        _freedom = State(initialValue: editing?.freedom ?? .ask)
        _notifications = State(initialValue: editing?.notifications ?? true)
        _skills = State(initialValue: editing?.skills ?? [])
        _plugins = State(initialValue: editing?.plugins ?? [])
        _connectors = State(initialValue: editing?.connectors ?? false)
    }

    var body: some View {
        SheetFrame(title: editing == nil ? String(localized: "New bot") : String(localized: "Bot settings"),
                   primary: editing == nil ? String(localized: "Create") : String(localized: "Save"),
                   canSubmit: canCreateBot(name: name, projectId: projectId), busy: busy, error: error, submit: submit,
                   cancel: { client.sheet = nil }) {
            if editing == nil {
                FieldGroup(label: String(localized: "Ready-made bots")) {
                    HStack(spacing: 8) {
                        templateCard(nil)
                        ForEach(BotTemplate.allCases, id: \.self) { templateCard($0) }
                    }
                }
            }
            if editing == nil && client.roster.projects.isEmpty {
                FieldGroup(label: String(localized: "Project")) {
                    Text(String(localized: "Create a project first")).foregroundStyle(Theme.textSecondary)
                    Button(String(localized: "New project…")) { client.showNewProject() }
                }
            } else if editing == nil {
                FieldGroup(label: String(localized: "Project")) {
                    Picker("", selection: $projectId) {
                        ForEach(client.roster.projects) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden()
                }
            }
            FieldGroup(label: String(localized: "Name")) {
                TextField(String(localized: "Bot name"), text: $name).textFieldStyle(.plain).font(.system(size: Theme.Size.body))
                    .focused($nameFocused)
                    .task { if editing == nil { try? await Task.sleep(for: .milliseconds(150)); nameFocused = true } }
                // Made by another bot with its tools (spec §7): who, read only.
                if let creator = editing?.createdBy.flatMap({ client.roster.bots[$0]?.bot.name }) {
                    Text(String(localized: "Created by \(creator)")).font(.system(size: Theme.Size.label))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            FieldGroup(label: String(localized: "Face")) {
                FacePicker(face: $face, existing: client.roster.bots.values.map(\.bot.face))
            }
            FieldGroup(label: String(localized: "Agent")) {
                // An agent only once the engine finds it ready (spec §7 of 0.3); for a bot that exists, changing it asks
                // first and starts a new conversation on the other agent (spec §7 of 0.7).
                Picker("", selection: $agent) {
                    Text("Claude Code").tag(Agent.claude).disabled(editing?.agent == .codex && claudeStatus?.problem != nil)
                    Text("Codex").tag(Agent.codex).disabled(codexStatus == nil || codexStatus?.problem != nil)
                }.pickerStyle(.segmented).labelsHidden().disabled(neverStarted)
                if neverStarted {
                    Text(String(localized: "Can change after the first start")).font(.system(size: Theme.Size.label))
                        .foregroundStyle(Theme.textSecondary)
                } else if let hint = agentHint {
                    HStack(spacing: 6) {
                        Text((try? AttributedString(markdown: hint)) ?? AttributedString(hint))
                        if codexChecked {
                            Link(String(localized: "Help"), destination: editing?.agent == .codex ? AgentCheckView.guide : AgentCheckView.codexGuide)
                        }
                    }
                    .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                }
                if let bot = editing, agent != baseAgent {
                    Text(String(localized: "\(bot.name) will start again with \(agentName(agent)) in a new conversation. The chat stays, the plugins are reset."))
                        .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if agent == .claude {
                    Picker(String(localized: "Model"), selection: $model) {
                        ForEach(BotModel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } else {
                    Picker(String(localized: "Model"), selection: $codexModel) {
                        Text(String(localized: "Default")).tag(String?.none)
                        ForEach(codexCatalog?.models ?? [], id: \.id) { Text($0.name).tag(Optional($0.id)) }
                        // The saved model before the catalog arrives (or when it no longer lists it): never a blank picker.
                        if let m = codexModel, codexCatalog?.models.contains(where: { $0.id == m }) != true { Text(m).tag(Optional(m)) }
                    }
                }
            }
            FieldGroup(label: String(localized: "Instructions")) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $instructions).scrollContentBackground(.hidden).font(.system(size: Theme.Size.body))
                        .frame(minHeight: 6 * 18)
                    if instructions.isEmpty {
                        Text(String(localized: "What does this bot do?")).foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 5).padding(.top, 0).allowsHitTesting(false)
                    }
                }
            }
            FieldGroup(label: String(localized: "Freedom")) {
                ForEach(Freedom.allCases, id: \.self) { f in
                    Button { freedom = f } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: freedom == f ? "largecircle.fill.circle" : "circle").padding(.top, 1)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.title).font(.system(size: Theme.Size.body))
                                Text(f.explanation(agent)).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            let project = client.roster.projects.first(where: { $0.id == projectId })
            // Each agent has its own lists (spec §6).
            FieldGroup(label: String(localized: "Skills")) {
                CatalogPicker(kind: .skills, items: agent == .claude ? catalog.skills : codexSkills, chosen: $skills,
                              inherited: project?.skills ?? [])
            }
            FieldGroup(label: String(localized: "Plugins")) {
                CatalogPicker(kind: .plugins, items: agent == .claude ? catalog.plugins : codexCatalog?.plugins ?? [], chosen: $plugins,
                              inherited: (agent == .claude ? project?.plugins : project?.codexPlugins) ?? [],
                              known: agent == .claude || codexCatalog != nil)
            }
            FieldGroup(label: agent == .claude ? String(localized: "claude.ai connectors") : String(localized: "ChatGPT connectors")) {
                Toggle(agent == .claude ? String(localized: "Use my claude.ai connectors") : String(localized: "Use my ChatGPT connectors"),
                       isOn: $connectors).toggleStyle(.switch)
                // The real names need a running agent: a fixed sentence (spec §6.4 of 0.3, §6).
                Text(agent == .claude
                     ? String(localized: "The services connected to your claude.ai account (for example Gmail or Home Assistant). They are turned on all together.")
                     : String(localized: "The services connected to your ChatGPT account. They are turned on all together. They include your account's web search."))
                    .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bot = editing {
                // Every change made to the bot (spec §5 of 0.7), newest first, each with Restore.
                FieldGroup(label: String(localized: "History")) {
                    if changes.isEmpty {
                        Text(String(localized: "No changes yet")).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                    }
                    let now = client.roster.bots[bot.id]?.bot.agent ?? bot.agent
                    ForEach(Array(changes.enumerated().reversed()), id: \.element.rowId) { i, change in
                        // A model or plugins value of the other agent cannot go back onto this one; skills are shared.
                        let otherAgent = [.model, .plugins].contains(change.field) && (agentAtChange(i) ?? now) != now
                        ChangeRow(change: change, author: authorName(change.by),
                                  restore: otherAgent ? nil : { restore(change, bot) })
                        if i > 0 { Divider().overlay(Theme.borderTertiary) }
                    }
                }
                // The bot's routines (spec §4 of 0.6): the live list, changed by the engine as runs go.
                FieldGroup(label: String(localized: "Routines")) {
                    let routines = client.roster.routines(of: bot.id)
                    if routines.isEmpty {
                        Text(String(localized: "No routines yet")).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(routines) { routine in
                        RoutineRow(routine: routine, client: client) { routineEditor = RoutineEditing(routine: routine) }
                        if routine.id != routines.last?.id { Divider().overlay(Theme.borderTertiary) }
                    }
                    Button(String(localized: "Add routine…")) { routineEditor = RoutineEditing(routine: nil) }
                }
                Toggle(String(localized: "Notifications"), isOn: $notifications).toggleStyle(.switch)
                Button(String(localized: "Archive bot"), role: .destructive) { confirmArchive = true }
                    .confirmationDialog(String(localized: "Archive this bot?"), isPresented: $confirmArchive) {
                        Button(String(localized: "Archive bot"), role: .destructive, action: archive)
                    } message: { Text(String(localized: "Its chat is kept, but it stops working.")) }
            }
        }
        .frame(width: 560).frame(minHeight: 360, idealHeight: height, maxHeight: height)
        .sheet(item: $routineEditor) { target in
            if let bot = editing {
                RoutineSheet(client: client, bot: bot, editing: target.routine) { routineEditor = nil }
            }
        }
        // Before the first frame: no pill drawn as missing for a moment, and a template picked at once finds its suggestions.
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            catalog = ClaudeCatalog(root: claudeConfigRoot(environment: env))
            codexSkills = catalog.codexSkills(environment: env)
        }
        .task {
            // Codex: for a new bot and for the switch of a Claude Code bot; Claude Code: for the switch of a Codex bot.
            if editing?.agent == .codex { claudeStatus = try? await client.agentStatus(.claude) }
            codexStatus = try? await client.agentStatus(.codex)
            codexChecked = true
            if codexStatus?.problem == nil, (editing?.agent ?? .codex) == .codex { codexCatalog = try? await client.codexCatalog() }
        }
        .task { if let id = editing?.id { changes = (try? await client.changes(bot: id)) ?? [] } }
        .onChange(of: agent) {
            if let bot = editing {
                // Against the form's own base, not `editing` (stale after a Restore of the agent, which sets `baseAgent`).
                if agent == baseAgent {            // back where it began (cancelled, or flipped back): the values as they were
                    if let s = stashed { (model, codexModel, plugins) = s; stashed = nil }
                    return
                }
                // Asked first, before any field is touched; the switch itself is done on Save (spec §7 of 0.7).
                guard confirmAgentChange(bot, to: agent) else { agent = baseAgent; return }
                if stashed == nil { stashed = (model, codexModel, plugins) }
            }
            // The two agents' models and plugins differ: what was picked for the other one goes; a template suggests anew.
            model = .standard; codexModel = nil
            if template != nil { suggest(template) } else { plugins = [] }
        }
    }

    /// A bot that exists but has had no first message yet: its agent can be changed after the first start (spec §7 of 0.7).
    private var neverStarted: Bool { editing.map { client.roster.bots[$0.id]?.started == false } ?? false }

    /// Why the other agent cannot be chosen yet, if so (spec §7 of 0.3, §7 of 0.7): the same help as the first launch.
    private var agentHint: String? {
        guard codexChecked else {
            return editing?.agent == .codex ? String(localized: "Checking Claude Code…") : String(localized: "Checking Codex…")
        }
        if editing?.agent == .codex {
            guard let status = claudeStatus, status.problem != nil else { return nil }
            return status.problem == .claudeNotSignedIn
                ? String(localized: "Claude Code is not signed in: type `claude` in Terminal.")
                : String(localized: "Claude Code is not installed.")
        }
        if let status = codexStatus, status.problem == nil { return nil }
        // Not installed, or a check that failed: either way Codex cannot be chosen.
        return codexStatus?.problem == .codexNotSignedIn
            ? String(localized: "Codex is not signed in: type `codex login` in Terminal.")
            : String(localized: "Codex is not installed: install the ChatGPT app or the Codex CLI.")
    }

    /// The confirmation of an agent switch (spec §7): true to go on.
    private func confirmAgentChange(_ bot: Bot, to agent: Agent) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Change the agent of \(bot.name)?")
        alert.informativeText = String(localized: "\(bot.name) will start again with \(agentName(agent)) in a new conversation. The chat stays, the plugins are reset.")
        alert.addButton(withTitle: String(localized: "Change agent"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The agent the bot had when `changes[i]` was recorded, read from the agent entries; nil when the history has none.
    private func agentAtChange(_ i: Int) -> Agent? {
        let value = changes[..<i].last { $0.field == .agent }?.new ?? changes.first { $0.field == .agent }?.old
        return value?.string.flatMap(Agent.init(rawValue:))
    }

    private func authorName(_ by: ChangeAuthor) -> String {
        switch by {
        case .user: String(localized: "You")
        case .bot(let id, let name): client.roster.bots[id]?.bot.name ?? name
        }
    }

    /// "Restore" (spec §5): the old value saved as a new change of yours, at once; the agent with the same confirmation
    /// and effects as the picker, the rest through the sheet's own save, so the fields here follow.
    private func restore(_ change: BotChange, _ bot: Bot) {
        guard let live = client.roster.bots[bot.id]?.bot, let restored = restoring(change, into: live) else {
            error = String(localized: "This value can no longer be restored"); return
        }
        error = nil
        Task {
            do {
                if change.field == .agent {
                    guard confirmAgentChange(live, to: restored.agent) else { return }
                    try await client.changeAgent(bot: bot.id, to: restored.agent)
                    baseAgent = restored.agent; stashed = nil; agent = restored.agent       // done already: no second confirmation
                    model = .standard; codexModel = nil; plugins = []                        // the engine reset them
                } else {
                    try await client.updateBot(restored)
                    (name, face, instructions, freedom, notifications) =
                        (restored.name, restored.face, restored.instructions, restored.freedom, restored.notifications)
                    (skills, plugins, connectors) = (restored.skills, restored.plugins, restored.connectors)
                    if restored.agent == .codex { codexModel = restored.model } else { model = BotModel(value: restored.model) }
                }
                changes = (try? await client.changes(bot: bot.id)) ?? changes
            } catch { self.error = error.localizedDescription }
        }
    }

    private func templateCard(_ t: BotTemplate?) -> some View {
        Button { apply(t) } label: {
            VStack(spacing: 4) {
                if let t { MascotImage(face: t.face, mood: .watch, size: 34) }
                else { Image(systemName: "square.dashed").font(.system(size: 24)).frame(height: 34) }
                Text(t?.title ?? String(localized: "Blank")).font(.system(size: Theme.Size.small)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(template == t ? Theme.active : Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row).stroke(Theme.text, lineWidth: template == t ? 2 : 0))    // as the face picker's
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Fills the form from a ready-made bot (or empties it for Blank); everything stays editable (spec §7).
    private func apply(_ t: BotTemplate?) {
        template = t
        name = t?.title ?? ""
        face = t?.face ?? randomFace(existing: client.roster.bots.values.map(\.bot.face))
        instructions = t?.instructions ?? ""
        freedom = t?.freedom ?? .ask
        suggest(t)
    }

    /// The template's skills and plugins found for the chosen agent, minus what the project already gives; the Researcher on
    /// Codex starts with the connectors on, its web search is there (spec §7).
    private func suggest(_ t: BotTemplate?) {
        let given = client.roster.projects.first { $0.id == projectId }
        let suggested = t?.suggestions(skills: agent == .claude ? catalog.skills : codexSkills,
                                       plugins: agent == .claude ? catalog.plugins : codexCatalog?.plugins ?? [])
        let givenPlugins = (agent == .claude ? given?.plugins : given?.codexPlugins) ?? []
        skills = suggested?.skills.filter { !(given?.skills.contains($0) ?? false) } ?? []
        plugins = suggested?.plugins.filter { !givenPlugins.contains($0) } ?? []
        if agent == .codex { connectors = t == .researcher }       // a Claude Code bot's stay as they are (0.3.1)
    }

    private func submit() {
        guard let projectId else { return }
        busy = true; error = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if let id = editing?.id {
                    // Re-read the live bot: pin, session etc. may have changed while the sheet was open.
                    guard let live = client.roster.bots[id]?.bot, live.archivedAt == nil else {
                        throw EngineError(message: String(localized: "This bot no longer exists"))
                    }
                    // The switch first (spec §7 of 0.7): refused, the sheet stays open with the reason. The engine
                    // resets model and plugins with it: the live ones go with the other edits, never the form's reset
                    // values, so no change of yours and no restart ride along; nothing else changed, nothing is sent.
                    let switching = agent != live.agent
                    if switching { try await client.changeAgent(bot: id, to: agent) }
                    let edited = live.applying(BotEdits(name: trimmed, face: face,
                        model: switching ? live.model : chosenModel, instructions: instructions, freedom: freedom,
                        notifications: notifications, skills: skills, plugins: switching ? live.plugins : plugins,
                        connectors: connectors))
                    if edited != live { try await client.updateBot(edited) }
                } else {
                    try await client.createBot(NewBot(projectId: projectId, name: trimmed, face: face, agent: agent,
                                                      model: chosenModel, instructions: instructions, freedom: freedom,
                                                      skills: skills, plugins: plugins, connectors: connectors))
                }
                client.sheet = nil
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }

    private var chosenModel: String? { agent == .claude ? model.value : codexModel }

    private func archive() {
        guard let id = editing?.id else { return }
        Task {
            do {
                try await client.archive(bot: id)
                if client.selectedBot == id { client.selectedBot = nil }
                client.sheet = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension BotTemplate {
    var title: String {
        switch self {
        case .developer: String(localized: "Developer")
        case .reviewer: String(localized: "Reviewer")
        case .researcher: String(localized: "Researcher")
        case .writer: String(localized: "Writer")
        }
    }
    var instructions: String {
        switch self {
        case .developer: String(localized: "You write and fix code in the project's linked folder. Read the code involved before changing it, run the tests after every change, and say what you checked.")
        case .reviewer: String(localized: "You review changes and find bugs without changing any file. For each problem, say where it is, why it matters and how to fix it.")
        case .researcher: String(localized: "You search the web and write reports. Check each fact in more than one source, say where it comes from, and save every report as a file in the project's shared folder.")
        case .writer: String(localized: "You write documents: texts, presentations and PDFs. Ask what the document is for and who will read it, then save it in the project's shared folder.")
        }
    }
}

private extension BotModel {
    var title: String {
        switch self {
        case .standard: String(localized: "Default")
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        }
    }
}

private extension Freedom {
    var title: String {
        switch self {
        case .ask: String(localized: "Asks permission")
        case .edits: String(localized: "Edits files on its own")
        case .auto: String(localized: "Automatic")
        }
    }
    /// What it means for the agent (spec §5: Codex works through its sandbox and approvals).
    func explanation(_ agent: Agent) -> String {
        switch (self, agent) {
        case (.ask, .claude): String(localized: "Asks you before running commands or editing files")
        case (.edits, .claude): String(localized: "Edits files without asking, asks for commands")
        case (.auto, .claude): String(localized: "Claude decides on its own what is safe")
        case (.ask, .codex): String(localized: "Reads on its own, asks before writing or leaving its folders")
        case (.edits, .codex): String(localized: "Writes in its folders without asking, asks for the rest")
        case (.auto, .codex): String(localized: "Never asks, and stays in its folders")
        }
    }
}

/// One change in the history (spec §5): when, who, which field, the old and the new value, and Restore. Instructions
/// show their first lines and open whole with a click.
private struct ChangeRow: View {
    let change: BotChange
    let author: String
    let restore: (() -> Void)?                 // nil: the value is of the other agent (spec §5)
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(change.at.formatted(date: .numeric, time: .shortened)) · \(author) · \(fieldLabel(change.field))")
                    .font(.system(size: Theme.Size.small, weight: .medium))
                Spacer(minLength: 8)
                if let restore { CardButton(title: String(localized: "Restore"), style: .ghost, action: restore) }
                else { Text(String(localized: "Other agent")).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textTertiary) }
            }
            HStack(alignment: .top, spacing: 6) {
                value(change.old)
                Text("→").foregroundStyle(Theme.textTertiary)
                value(change.new)
            }
            .font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
    }

    @ViewBuilder private func value(_ v: JSONValue) -> some View {
        if change.field == .face, let data = try? v.encoded(), let face = try? JSONDecoder().decode(BotFace.self, from: data) {
            MascotImage(face: face, mood: .watch, size: 22)
        } else {
            Text(valueText(v)).lineLimit(open ? nil : 3).textSelection(.enabled)
        }
    }

    private func valueText(_ v: JSONValue) -> String {
        switch v {
        case .null: String(localized: "Default")
        case .bool(let b): b ? String(localized: "on") : String(localized: "off")
        case .string(let s):
            switch change.field {
            case .freedom: Freedom(rawValue: s).map(freedomLabel) ?? s
            case .agent: Agent(rawValue: s).map(agentName) ?? s
            default: s.isEmpty ? "—" : s
            }
        case .array(let list): list.isEmpty ? "—" : list.compactMap(\.string).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        default: v.compactText
        }
    }
}

private extension BotChange {
    /// A stable identity for the history list (the entry's time and field), so a row keeps its open state.
    var rowId: String { "\(at.timeIntervalSince1970)-\(field.rawValue)" }
}

func fieldLabel(_ field: BotField) -> String {
    switch field {
    case .name: String(localized: "Name")
    case .face: String(localized: "Face")
    case .instructions: String(localized: "Instructions")
    case .model: String(localized: "Model")
    case .freedom: String(localized: "Freedom")
    case .skills: String(localized: "Skills")
    case .plugins: String(localized: "Plugins")
    case .connectors: String(localized: "Connectors")
    case .agent: String(localized: "Agent")
    case .notifications: String(localized: "Notifications")
    }
}

func freedomLabel(_ f: Freedom) -> String {
    switch f {
    case .ask: String(localized: "Asks permission")
    case .edits: String(localized: "Edits files on its own")
    case .auto: String(localized: "Automatic")
    }
}
