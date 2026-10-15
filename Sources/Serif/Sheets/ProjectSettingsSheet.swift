import SwiftUI
import SerifCore

/// Settings of an existing project (spec §6.4): name, linked folder and its instructions, the skills and plugins every
/// bot of the project gets, and its lead (spec §8 of 0.5). The engine restarts the project's bots when what reaches
/// them changes; a new lead restarts nobody.
struct ProjectSettingsSheet: View {
    let client: EngineClient
    let projectId: UUID
    @State private var name: String
    @State private var folder: String?
    @State private var readInstructions: Bool
    @State private var skills: [String]
    @State private var plugins: [String]
    @State private var codexPlugins: [String]
    @State private var lead: UUID?
    @State private var catalog = ClaudeCatalog()
    @State private var codexCatalog: CodexCatalog?       // asked of the engine when the sheet opens
    @State private var decisions: [Decision] = []        // the project's, open first (spec §6 of 0.6)
    @State private var busy = false
    @State private var error: String?

    init(client: EngineClient, project: Project) {
        self.client = client
        projectId = project.id
        _name = State(initialValue: project.name)
        _folder = State(initialValue: project.linkedFolder)
        _readInstructions = State(initialValue: project.readLinkedInstructions)
        _skills = State(initialValue: project.skills)
        _plugins = State(initialValue: project.plugins)
        _codexPlugins = State(initialValue: project.codexPlugins)
        _lead = State(initialValue: project.leadBotId)
    }

    /// The project's active bots, by name: the lead is one of them.
    private var leads: [Bot] {
        client.roster.bots.values.map(\.bot).filter { $0.projectId == projectId && $0.archivedAt == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SheetFrame(title: String(localized: "Project settings"), primary: String(localized: "Save"),
                   canSubmit: canCreateProject(name: name), busy: busy, error: error, submit: save,
                   cancel: { client.sheet = nil }) {
            ProjectFields(name: $name, folder: $folder, readInstructions: $readInstructions, focusName: false)
            FieldGroup(label: String(localized: "Skills")) { CatalogPicker(kind: .skills, items: catalog.skills, chosen: $skills) }
            // The two apps' plugins differ: one list each (spec §6).
            FieldGroup(label: String(localized: "Plugins for Claude Code bots")) {
                CatalogPicker(kind: .plugins, items: catalog.plugins, chosen: $plugins)
            }
            FieldGroup(label: String(localized: "Plugins for Codex bots")) {
                CatalogPicker(kind: .plugins, items: codexCatalog?.plugins ?? [], chosen: $codexPlugins, known: codexCatalog != nil)
            }
            Text(String(localized: "Every bot of the project gets these skills and plugins. Changing them, the linked folder or its switch restarts the project's bots."))
                .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FieldGroup(label: String(localized: "Project lead")) {
                Picker("", selection: $lead) {
                    Text(String(localized: "Lead.none")).tag(UUID?.none)
                    ForEach(leads) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden()
            }
            FieldGroup(label: String(localized: "Decisions")) {
                if decisions.isEmpty {
                    Text(String(localized: "No decisions yet")).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(decisions.sorted { ($0.status != .open ? 1 : 0, -$0.number) < ($1.status != .open ? 1 : 0, -$1.number) },
                        id: \.number) { d in
                    DecisionLine(decision: d, botName: client.roster.bots[d.botId]?.bot.name ?? "?")
                }
            }
        }
        .frame(width: 520).frame(minHeight: 360, idealHeight: sheetHeight(840), maxHeight: sheetHeight(840))
        .onAppear { catalog = ClaudeCatalog(root: claudeConfigRoot(environment: ProcessInfo.processInfo.environment)) }    // before the first frame
        .task { codexCatalog = try? await client.codexCatalog() }
        .task { decisions = (try? await client.decisions(project: projectId)) ?? [] }
    }

    /// One decision, read only (spec §6 of 0.6): number, bot, question, state, answer, date.
    private struct DecisionLine: View {
        let decision: Decision
        let botName: String
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("#\(decision.number) · \(botName)").font(.system(size: Theme.Size.body, weight: .medium))
                    Spacer(minLength: 8)
                    StatusPill(kind: pill.kind, text: pill.text)
                }
                Text(decision.question).font(.system(size: Theme.Size.body)).textSelection(.enabled)
                if decision.status == .answered {
                    Text(String(localized: "Answer: \(decisionAnswerText(decision))")).font(.system(size: Theme.Size.small))
                        .foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                }
                if let reason = decision.reason, !reason.isEmpty {
                    Text(reason).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                }
                Text((decision.answeredAt ?? decision.createdAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 4)
        }
        private var pill: (kind: StatusPill.Kind, text: String) {
            switch decision.status {
            case .open: (.waiting, String(localized: "Decision.open"))
            case .answered: (.done, String(localized: "Answered"))
            case .withdrawn: (.neutral, String(localized: "Withdrawn"))
            }
        }
    }

    private func save() {
        // The live project: what this sheet does not show stays as the engine has it.
        guard var project = client.roster.projects.first(where: { $0.id == projectId }) else {
            error = String(localized: "This project no longer exists")
            return
        }
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.linkedFolder = folder
        project.readLinkedInstructions = readInstructions
        project.skills = skills
        project.plugins = plugins
        project.codexPlugins = codexPlugins
        project.leadBotId = lead
        busy = true; error = nil
        Task {
            do { try await client.updateProject(project); client.sheet = nil }
            catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
