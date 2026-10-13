import SwiftUI
import SerifCore

/// Settings of an existing project (spec §6.4): name, linked folder and its instructions, and the skills and plugins every
/// bot of the project gets. The engine restarts the project's bots when what reaches them changes.
struct ProjectSettingsSheet: View {
    let client: EngineClient
    let projectId: UUID
    @State private var name: String
    @State private var folder: String?
    @State private var readInstructions: Bool
    @State private var skills: [String]
    @State private var plugins: [String]
    @State private var catalog = ClaudeCatalog()
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
    }

    var body: some View {
        SheetFrame(title: String(localized: "Project settings"), primary: String(localized: "Save"),
                   canSubmit: canCreateProject(name: name), busy: busy, error: error, submit: save,
                   cancel: { client.sheet = nil }) {
            ProjectFields(name: $name, folder: $folder, readInstructions: $readInstructions, focusName: false)
            FieldGroup(label: String(localized: "Skills")) { CatalogPicker(kind: .skills, items: catalog.skills, chosen: $skills) }
            FieldGroup(label: String(localized: "Plugins")) { CatalogPicker(kind: .plugins, items: catalog.plugins, chosen: $plugins) }
            Text(String(localized: "Every bot of the project gets these skills and plugins; changing them restarts its bots."))
                .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 520).frame(minHeight: 360, idealHeight: sheetHeight(640), maxHeight: sheetHeight(640))
        .task { catalog = ClaudeCatalog(root: claudeConfigRoot(environment: ProcessInfo.processInfo.environment)) }
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
        busy = true; error = nil
        Task {
            do { try await client.updateProject(project); client.sheet = nil }
            catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
