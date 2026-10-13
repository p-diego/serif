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
    @State private var model: BotModel
    @State private var instructions: String
    @State private var freedom: Freedom
    @State private var notifications: Bool
    @State private var skills: [String]
    @State private var plugins: [String]
    @State private var connectors: Bool
    @State private var catalog = ClaudeCatalog()          // read when the sheet opens
    @State private var busy = false
    @State private var error: String?
    @State private var confirmArchive = false
    @State private var height = sheetHeight(1200)    // measured once: never re-derived while typing
    @FocusState private var nameFocused: Bool

    init(client: EngineClient, editing: Bot?, projectId: UUID?) {
        self.client = client
        self.editing = editing
        let roster = client.roster
        _projectId = State(initialValue: editing?.projectId ?? projectId
            ?? defaultProjectId(projects: roster.projects, selectedBotProject: client.selectedBot.flatMap { roster.bots[$0]?.bot.projectId }))
        _name = State(initialValue: editing?.name ?? "")
        _face = State(initialValue: editing?.face ?? randomFace(existing: roster.bots.values.map(\.bot.face)))
        _model = State(initialValue: BotModel(value: editing?.model))
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
            }
            FieldGroup(label: String(localized: "Face")) {
                FacePicker(face: $face, existing: client.roster.bots.values.map(\.bot.face))
            }
            FieldGroup(label: String(localized: "Agent")) {
                Picker("", selection: .constant(Agent.claude)) {
                    Text("Claude Code").tag(Agent.claude)
                    Text(String(localized: "Codex — soon")).tag(Agent.codex).disabled(true)
                }.pickerStyle(.segmented).labelsHidden()
                Picker(String(localized: "Model"), selection: $model) {
                    ForEach(BotModel.allCases, id: \.self) { Text($0.title).tag($0) }
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
                                Text(f.explanation).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            let project = client.roster.projects.first(where: { $0.id == projectId })
            FieldGroup(label: String(localized: "Skills")) {
                CatalogPicker(kind: .skills, items: catalog.skills, chosen: $skills, inherited: project?.skills ?? [])
            }
            FieldGroup(label: String(localized: "Plugins")) {
                CatalogPicker(kind: .plugins, items: catalog.plugins, chosen: $plugins, inherited: project?.plugins ?? [])
            }
            FieldGroup(label: String(localized: "claude.ai connectors")) {
                Toggle(String(localized: "Use my claude.ai connectors"), isOn: $connectors).toggleStyle(.switch)
                // The real names need a running Claude Code: a fixed sentence (spec §6.4).
                Text(String(localized: "The services connected to your claude.ai account (for example Gmail or Home Assistant). They are turned on all together."))
                    .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editing != nil {
                Toggle(String(localized: "Notifications"), isOn: $notifications).toggleStyle(.switch)
                Button(String(localized: "Archive bot"), role: .destructive) { confirmArchive = true }
                    .confirmationDialog(String(localized: "Archive this bot?"), isPresented: $confirmArchive) {
                        Button(String(localized: "Archive bot"), role: .destructive, action: archive)
                    } message: { Text(String(localized: "Its chat is kept, but it stops working.")) }
            }
        }
        .frame(width: 560).frame(minHeight: 360, idealHeight: height, maxHeight: height)
        .task { catalog = ClaudeCatalog(root: claudeConfigRoot(environment: ProcessInfo.processInfo.environment)) }
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
        let suggested = t?.suggestions(in: catalog)
        skills = suggested?.skills ?? []
        plugins = suggested?.plugins ?? []
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
                    try await client.updateBot(live.applying(BotEdits(name: trimmed, face: face, model: model.value,
                        instructions: instructions, freedom: freedom, notifications: notifications,
                        skills: skills, plugins: plugins, connectors: connectors)))
                } else {
                    try await client.createBot(NewBot(projectId: projectId, name: trimmed, face: face, agent: .claude,
                                                      model: model.value, instructions: instructions, freedom: freedom,
                                                      skills: skills, plugins: plugins, connectors: connectors))
                }
                client.sheet = nil
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }

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
    var explanation: String {
        switch self {
        case .ask: String(localized: "Asks you before running commands or editing files")
        case .edits: String(localized: "Edits files without asking, asks for commands")
        case .auto: String(localized: "Claude decides on its own what is safe")
        }
    }
}
