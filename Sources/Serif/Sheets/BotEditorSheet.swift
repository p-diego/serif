import SwiftUI
import SerifCore

/// New bot (`editing == nil`) or settings of an existing one.
struct BotEditorSheet: View {
    let client: EngineClient
    let editing: Bot?
    @State private var projectId: UUID?
    @State private var name: String
    @State private var face: BotFace
    @State private var model: BotModel
    @State private var instructions: String
    @State private var freedom: Freedom
    @State private var notifications: Bool
    @State private var busy = false
    @State private var error: String?
    @State private var confirmArchive = false
    @State private var height = sheetHeight(820)    // measured once: never re-derived while typing
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
    }

    var body: some View {
        SheetFrame(title: editing == nil ? String(localized: "New bot") : String(localized: "Bot settings"),
                   primary: editing == nil ? String(localized: "Create") : String(localized: "Save"),
                   canSubmit: canCreateBot(name: name, projectId: projectId), busy: busy, error: error, submit: submit,
                   cancel: { client.sheet = nil }) {
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
            if editing != nil {
                Toggle(String(localized: "Notifications"), isOn: $notifications).toggleStyle(.switch)
                Button(String(localized: "Archive bot"), role: .destructive) { confirmArchive = true }
                    .confirmationDialog(String(localized: "Archive this bot?"), isPresented: $confirmArchive) {
                        Button(String(localized: "Archive bot"), role: .destructive, action: archive)
                    } message: { Text(String(localized: "Its chat is kept, but it stops working.")) }
            }
        }
        .frame(width: 560).frame(minHeight: 360, idealHeight: height, maxHeight: height)
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
                        instructions: instructions, freedom: freedom, notifications: notifications)))
                } else {
                    try await client.createBot(NewBot(projectId: projectId, name: trimmed, face: face, agent: .claude,
                                                      model: model.value, instructions: instructions, freedom: freedom))
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
