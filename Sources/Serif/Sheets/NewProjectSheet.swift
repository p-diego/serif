import SwiftUI
import AppKit
import SerifCore

/// Common frame of the sheets: title, scrolling content, Cancel / primary button.
struct SheetFrame<Content: View>: View {
    let title: String
    let primary: String
    let canSubmit: Bool
    let busy: Bool
    let error: String?
    let submit: () -> Void
    let cancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: Theme.Size.title, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            ScrollView { VStack(alignment: .leading, spacing: 16) { content }.padding(.horizontal, 24).padding(.bottom, 8) }
            HStack(spacing: 10) {
                if let error { Text(error).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.red).lineLimit(2) }
                Spacer()
                Button(String(localized: "Cancel"), action: cancel).buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(Capsule().fill(Theme.fillSecondary))
                Button(action: submit) { Text(primary).foregroundStyle(Theme.userBubbleText) }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                    .padding(.horizontal, 20).frame(height: 36)
                    .background(Capsule().fill(Theme.userBubble.opacity(canSubmit && !busy ? 1 : 0.35)))
                    .disabled(!canSubmit || busy)
            }
            .font(.system(size: Theme.Size.body, weight: .medium))
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.pane)
    }
}

/// A labelled rounded group, the form's unit.
struct FieldGroup<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: Theme.Size.label, weight: .medium)).foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.fillSecondary))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row).stroke(Theme.border, lineWidth: 0.5))
        }
    }
}

/// Name, linked folder and the switch for its instructions: the New project sheet, the project settings and the first
/// launch's last step.
struct ProjectFields: View {
    @Binding var name: String
    @Binding var folder: String?
    @Binding var readInstructions: Bool
    var focusName = true
    @FocusState private var nameFocused: Bool

    var body: some View {
        FieldGroup(label: String(localized: "Name")) {
            TextField(String(localized: "Project name"), text: $name).textFieldStyle(.plain).font(.system(size: Theme.Size.body))
                .focused($nameFocused).onAppear { if focusName { nameFocused = true } }
        }
        FieldGroup(label: String(localized: "Linked folder")) {
            HStack {
                Text(folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "None"))
                    .foregroundStyle(folder == nil ? Theme.textTertiary : Theme.text).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(String(localized: "Choose…"), action: chooseFolder)
                if folder != nil { Button(String(localized: "Remove")) { folder = nil } }
            }
            if folder != nil {
                Toggle(String(localized: "Let the bots read the linked folder's instructions"), isOn: $readInstructions)
                    .toggleStyle(.switch)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { folder = panel.url?.path }
    }
}

struct NewProjectSheet: View {
    let client: EngineClient
    @State private var name = ""
    @State private var folder: String?
    @State private var readInstructions = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SheetFrame(title: String(localized: "New project"), primary: String(localized: "Create"),
                   canSubmit: canCreateProject(name: name), busy: busy, error: error, submit: create,
                   cancel: { client.sheet = nil }) {
            ProjectFields(name: $name, folder: $folder, readInstructions: $readInstructions)
        }
        .frame(width: 460).frame(minHeight: 260, idealHeight: sheetHeight(folder == nil ? 300 : 340), maxHeight: sheetHeight(folder == nil ? 300 : 340))
    }

    private func create() {
        busy = true; error = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let project = try await client.createProject(name: trimmed, linkedFolder: folder, readLinkedInstructions: readInstructions)
                // A project has no chat: with no bots yet, go straight to the first one.
                client.sheet = client.roster.bots.isEmpty ? .newBot(projectId: project.id) : nil
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

/// Height for a sheet: its natural one, but never taller than the window minus 80 pt (the content scrolls inside).
@MainActor func sheetHeight(_ natural: CGFloat) -> CGFloat {
    // Always measure the window the sheet hangs from, never the sheet itself (it becomes the key window).
    let host = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
    return min(natural, (host?.frame.height ?? natural + 80) - 80)
}
