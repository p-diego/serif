import SwiftUI
import AppKit
import SerifCore

/// The demo's "Computer" card for a group of tool calls.
struct StepsCard: View {
    let steps: [Step]
    let status: StepsStatus
    @Binding var expanded: Bool    // owned by the chat so it survives the lazy list recycling rows
    @Binding var open: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: Theme.Size.body, weight: .medium))
                Spacer(minLength: 8)
                StatusPill(kind: pillKind, text: pillText)
            }
            Text(summary).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps) { step in stepRow(step) }
                }
                .padding(.top, 2)
            }
        }
        .padding(12).frame(maxWidth: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.botBubble))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pillKind: StatusPill.Kind { switch status { case .done: .done; case .failed: .failed; case .running: .running } }
    private var pillText: String {
        switch status { case .done: String(localized: "Done"); case .failed: String(localized: "Error"); case .running: String(localized: "In progress") }
    }

    private var title: String {
        switch stepsKind(steps) {
        case .commands: String(localized: "Commands")
        case .files: String(localized: "Files")
        case .search: String(localized: "Steps.search")
        case .web: String(localized: "Web")
        case .mixed(let name):
            // Serif's own tools read as what they did (spec §9 of 0.5), for one step; "mcp__server__tool" as "tool".
            if steps.count == 1, steps[0].ok != false, let call = SerifToolCall(toolName: name, input: steps[0].input) {
                serifStepTitle(call)
            } else {
                name.isEmpty ? String(localized: "Steps") : plainName(name)
            }
        }
    }

    private func title(_ step: Step) -> String {
        // A failed Serif call must not read as done ("Task #17 closed"): its plain name instead.
        guard let call = SerifToolCall(toolName: step.name, input: step.input) else { return step.title }
        return step.ok == false ? plainName(step.name) : serifStepTitle(call)
    }

    /// "mcp__server__tool" as "tool".
    private func plainName(_ name: String) -> String {
        name.components(separatedBy: "__").last.flatMap { $0.isEmpty ? nil : $0 } ?? name
    }

    private var summary: String {
        let c = stepsCounts(steps)
        var parts: [String] = []
        if c.commands > 0 { parts.append(c.commands == 1 ? String(localized: "1 command") : String(localized: "\(c.commands) commands")) }
        if c.filesRead > 0 { parts.append(c.filesRead == 1 ? String(localized: "1 file read") : String(localized: "\(c.filesRead) files read")) }
        if c.filesEdited > 0 { parts.append(c.filesEdited == 1 ? String(localized: "1 file edited") : String(localized: "\(c.filesEdited) files edited")) }
        if c.searches > 0 { parts.append(c.searches == 1 ? String(localized: "1 search") : String(localized: "\(c.searches) searches")) }
        if c.other > 0 { parts.append(c.other == 1 ? String(localized: "1 other step") : String(localized: "\(c.other) other steps")) }
        return parts.joined(separator: " · ")
    }

    private func icon(_ name: String) -> String {
        switch name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebSearch", "WebFetch": "globe"
        case _ where name.hasPrefix("mcp__serif__"): "envelope"
        default: "wrench.and.screwdriver"
        }
    }

    @ViewBuilder private func stepRow(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon(step.name)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                Text(title(step))
                    .font(step.name == "Bash" ? .system(size: 12, design: .monospaced) : .system(size: Theme.Size.small))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if step.ok == false { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.red) }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open = open == step.id ? nil : step.id } }
            if open == step.id { output(step) }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func output(_ step: Step) -> some View {
        let text = step.output ?? ""
        VStack(alignment: .trailing, spacing: 4) {
            ScrollView {
                Text(text.isEmpty ? String(localized: "No output") : text)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 20 * 15)
            .fixedSize(horizontal: false, vertical: true)    // short outputs stay short
            if !text.isEmpty {
                Button(String(localized: "Copy")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.plain).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.codeBackground))
    }
}
